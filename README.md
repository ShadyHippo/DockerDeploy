# DockerDeploy

Run one of your audited deploy scripts **by name**, from another container.

```
POST /run/easyedit   ->   /scripts/easyedit.sh
```

No arguments, no request-supplied paths, no shell, no inherited environment.
Scripts live on the host, are mounted read-only, and adding one needs no restart.

## Why

An agent running in a container needs to say "pull the new image and recreate
this stack". It should not get the Docker socket to do that: the socket is
root-equivalent, and an agent is the least trustworthy process on the box — it
reads untrusted code, web pages, issues and dependency READMEs. One prompt
injection away from `docker run --privileged -v /:/host` is not a place to be.

This is the smallest thing that turns a *name* into a host-side
`docker compose up -d`: a directory of scripts you wrote, and a dispatcher that
will only ever run those. The agent's capability becomes "recreate one of these
N stacks", which is all a release needs.

It is the deploy half of the
[CodeContainer](https://github.com/ShadyHippo/CodeContainer) agent sandbox, and
works with anything else that can reach a Docker network.

## How it works

```
caller ──HTTP──▶ docker-deploy ──execve──▶ /scripts/<name>.sh ──docker──▶ /var/run/docker.sock ──▶ dockerd
```

- The scripts run **inside** this container, as root, with the socket mounted.
  That is what makes `docker compose` work.
- The scripts directory is mounted **read-only** at `/scripts`, so a caller can
  never add or edit what is runnable.
- The directory is listed on every request. New script, next call — no restart.

## Layout

```
/mnt/user/appdata/docker_projects/DockerDeploy/     this checkout
  compose.yaml
  server.py
  scripts/            the allowlist, mounted read-only
    ping.sh
    easyedit.sh       yours
  docker/             DOCKER_CONFIG (gitignored)
  secrets/gh_pat      registry token (gitignored), mounted at /secrets

/mnt/user/appdata/docker_projects/                   the stacks
  EasyEdit-Photos/
  MusicScan/
```

## Quick start

```bash
git clone https://github.com/ShadyHippo/DockerDeploy.git \
  /mnt/user/appdata/docker_projects/DockerDeploy
cd /mnt/user/appdata/docker_projects/DockerDeploy

mkdir -p docker
chown root:root scripts docker
chmod 755 scripts docker
chmod 755 scripts/*.sh

docker compose pull
docker compose up -d
```

Then, from any container on the `deploy-net` network:

```bash
curl -fsS -XPOST http://docker-deploy:9000/run/ping
```

`ping.sh` reports the script's uid, cwd, `$#`, the daemon version and each
mount's state, without touching a stack.

## API

| Method | Path | Result |
|---|---|---|
| `POST` | `/run/<name>` | runs `/scripts/<name>.sh`; returns `rc`, `duration_ms`, log tail |
| `GET` | `/scripts` | names currently callable |
| `GET` | `/health` | liveness |

A successful script returns `200`; a non-zero exit returns `500` with the same
body so the caller can read the log either way. Unknown names return `404` with
the current list. A name already running returns `409`.

```json
{"script": "easyedit", "rc": 0, "duration_ms": 8123, "log": "updated\n"}
```

## Adding a script

Write `scripts/<name>.sh` in this checkout. It must be:

- a regular file (no symlinks),
- owned by `root`,
- executable by its owner,
- not writable by group or others,

and the directory must be root-owned and not group/other writable.

```bash
chown root:root scripts/myservice.sh
chmod 755 scripts/myservice.sh
```

This matters on Unraid: files under `/mnt/user` default to `nobody:nobody`, so
"owner-writable" would mean any SMB user could edit a script root then executes.
The server refuses such a file rather than run it. `scripts/README.md` has the
full contract and a template.

## Security model

Mapping only the scripts directory means the host's filesystem does not exist in
the container's view — `../../etc/shadow` resolves inside the container, not on
the host. On top of that, every request is checked:

| Check | Stops |
|---|---|
| Name must match `^[a-z0-9][a-z0-9_-]{0,63}$` | `/`, `..`, dots, absolute paths, URL tricks |
| `lstat` + require a regular file | symlinks pointing anywhere else |
| Owner must be `root` | a `nobody`-owned script anyone on the share can edit |
| Not writable by group/others | a script another local user can modify |
| Owner-executable | data files being executed |
| `realpath` parent must equal `/scripts` | any residual path trick |
| `scripts/` mounted `:ro` | a caller adding or editing scripts |
| `execve([path])`, no args, fixed env, `cwd=/`, stdin `/dev/null` | steering the script with input |
| Per-name `flock` | two deploys of the same stack at once |

**The caveat:** the container holds `/var/run/docker.sock`, which is
root-equivalent. A breach of `server.py`, or a shell inside this container, can
reach every container, image and volume on the host. The allowlist bounds what
*this code* executes; it is not a sandbox. Keep the image thin, keep the code
small, and do not publish the port.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SCRIPT_DIR` | `/scripts` | allowlist path inside the container |
| `RUN_TIMEOUT` | `3600` | seconds before a script is killed (build stacks can take 20+ min) |
| `LISTEN_HOST` | `0.0.0.0` | bind address |
| `LISTEN_PORT` | `9000` | port |
| `LOG_TAIL` | `8000` | characters of output returned to the caller |
| `PROJECTS_DIR` | `/mnt/user/appdata/docker_projects` | stacks, mounted at the same path (compose) |

## Using it from a sandboxed agent

Put any container that needs to trigger releases on the same network:

```yaml
services:
  yourapp:
    networks:
      default: {}
      deploy-net: {}

networks:
  deploy-net:
    external: true
```

Then, from inside it:

```bash
curl -s http://docker-deploy:9000/scripts
curl -s -XPOST http://docker-deploy:9000/run/easyedit
```

No ports are published, so it is reachable only from containers on that network
— not from the LAN, the tailnet or the internet. The agent needs no socket, no
host shell, and no credentials for the registry; the deploy scripts hold those.

This is how [CodeContainer](https://github.com/ShadyHippo/CodeContainer) releases
its own stacks, including itself (`POST /run/codecontainer` recreates the agent's
container, so it ends the session that asked for it).

## Private registries

The token is mounted, not copied. Put it in `secrets/gh_pat` (gitignored, so it
never reaches this repo) — the directory is mounted read-only at `/secrets`:

```bash
install -m 600 /dev/null secrets/gh_pat
$EDITOR secrets/gh_pat          # paste the PAT, no trailing newline
```

and in the script:

```bash
export DOCKER_CONFIG=/root/.docker
tr -d '\n' < /secrets/gh_pat \
  | docker login ghcr.io -u <user> --password-stdin
```

`/root` is RAM on Unraid, which is why `DOCKER_CONFIG` points at the mounted
`docker/` directory instead of the default.

## Building

```bash
docker build -t ghcr.io/shadyhippo/dockerdeploy:latest .
# or daemonless:
buildah bud -t ghcr.io/shadyhippo/dockerdeploy:latest .
```

CI also builds and pushes `:latest` and a short-sha tag on every push to `main`.
