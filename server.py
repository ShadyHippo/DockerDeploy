#!/usr/bin/env python3
"""docker-deploy: run one audited deploy script, selected by name only.

    POST /run/<name>    run <SCRIPT_DIR>/<name>.sh
    GET  /scripts       names currently callable
    GET  /health        liveness

The caller supplies a name and nothing else: no arguments, no request-supplied
paths, no shell, and no inheritance of the caller's environment or cwd. The
script directory is mounted read-only, so a caller can never add to or modify
what is runnable.

This container holds /var/run/docker.sock, which is root-equivalent. The checks
below bound what *this code* will execute. They do not bound what the container
could do if it were compromised -- keep the code small, keep the image thin.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import stat
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT_DIR = os.path.realpath(os.environ.get("SCRIPT_DIR", "/scripts"))
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9000"))
RUN_TIMEOUT = int(os.environ.get("RUN_TIMEOUT", "1800"))
LOG_TAIL = int(os.environ.get("LOG_TAIL", "8000"))

# Lowercase, no dots, no slashes, no leading dash. The name can only ever be a
# single path component that we append ".sh" to.
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

# Scripts run with this environment, never the caller's.
RUN_ENV = {
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "HOME": "/root",
    "DOCKER_CONFIG": "/root/.docker",
    "LANG": "C.UTF-8",
}


def _trusted(st: os.stat_result) -> bool:
    """A runnable script: regular file, root-owned, executable, not writable by
    group or others.

    The ownership check matters on Unraid: files on /mnt/user are often owned by
    nobody:nobody, so "owner-writable" would mean an SMB user can edit a script
    that root then executes.
    """
    return (
        stat.S_ISREG(st.st_mode)
        and st.st_uid == 0
        and bool(st.st_mode & stat.S_IXUSR)
        and not (st.st_mode & (stat.S_IWGRP | stat.S_IWOTH))
    )


def resolve(name: str) -> str | None:
    """Map a name to a script path, or None. Never leaves SCRIPT_DIR."""
    if not NAME_RE.fullmatch(name):
        return None

    path = os.path.join(SCRIPT_DIR, name + ".sh")
    try:
        # lstat: a symlink is not a regular file, so it is rejected outright
        # rather than followed out of the directory.
        st = os.lstat(path)
    except OSError:
        return None

    if not _trusted(st):
        return None

    # Belt and braces: even if something above were bypassed, the resolved
    # parent must still be the script directory.
    if os.path.dirname(os.path.realpath(path)) != SCRIPT_DIR:
        return None
    return path


def discover() -> list[str]:
    """Re-read the directory on every call, so a new script needs no restart."""
    try:
        entries = os.listdir(SCRIPT_DIR)
    except OSError:
        return []
    names = []
    for fn in entries:
        if not fn.endswith(".sh"):
            continue
        name = fn[:-3]
        if resolve(name) is not None:
            names.append(name)
    return sorted(names)


def check_dir() -> None:
    try:
        st = os.stat(SCRIPT_DIR)
    except OSError as exc:
        print(f"[startup] !! cannot stat {SCRIPT_DIR}: {exc}", file=sys.stderr, flush=True)
        return
    if st.st_uid != 0:
        print(
            f"[startup] !! {SCRIPT_DIR} is not root-owned (uid {st.st_uid}); "
            f"run: chown -R root:root {SCRIPT_DIR}",
            file=sys.stderr,
            flush=True,
        )
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        print(
            f"[startup] !! {SCRIPT_DIR} is group/other writable; "
            f"run: chmod 755 {SCRIPT_DIR}",
            file=sys.stderr,
            flush=True,
        )


class Handler(BaseHTTPRequestHandler):
    server_version = "docker-deploy/1"

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        if self.path in ("/health", "/scripts"):
            return self._json(200, {"ok": True, "scripts": discover()})
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - http.server API
        if not self.path.startswith("/run/"):
            return self._json(404, {"error": "not found"})

        name = self.path[len("/run/"):]
        if "/" in name or "?" in name:
            return self._json(400, {"error": "a single script name is required"})

        script = resolve(name)
        if script is None:
            return self._json(404, {"error": f"no such script: {name}", "scripts": discover()})

        started = time.monotonic()
        with open(f"/tmp/{name}.lock", "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return self._json(409, {"error": f"{name} is already running"})

            try:
                proc = subprocess.run(
                    [script],  # execve; no shell, no arguments
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    timeout=RUN_TIMEOUT,
                    cwd="/",
                    env=RUN_ENV,
                )
                rc = proc.returncode
                output = proc.stdout + proc.stderr
            except subprocess.TimeoutExpired:
                rc, output = 124, f"timed out after {RUN_TIMEOUT}s"
            except OSError as exc:
                rc, output = 126, f"could not execute: {exc}"

        took_ms = int((time.monotonic() - started) * 1000)
        print(f"[run] {self.client_address[0]} {name} rc={rc} {took_ms}ms", flush=True)

        self._json(
            200 if rc == 0 else 500,
            {"script": name, "rc": rc, "duration_ms": took_ms, "log": output[-LOG_TAIL:]},
        )

    def log_message(self, fmt: str, *args) -> None:
        print(f"[http] {self.client_address[0]} {fmt % args}", flush=True)


def main() -> None:
    check_dir()
    names = discover()
    print(
        f"[startup] {SCRIPT_DIR}: {len(names)} callable script(s): "
        + (", ".join(names) if names else "(none)"),
        flush=True,
    )
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    httpd.daemon_threads = True
    print(f"[startup] listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
