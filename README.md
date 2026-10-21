# DockerDeploy

Run one of your audited deploy scripts **by name**, from another container.

```
POST /run/easyedit   ->   /scripts/easyedit.sh
```

No arguments, no request-supplied paths, no shell, no inherited environment.
Scripts live on the host, are mounted read-only, and adding one needs no restart.

## Why

An agent running in a container needs to say "pull the new image and recreate
this stack". It should not get the Docker socket to do that. This container is
the smallest thing that turns a name into a host-side `docker compose up -d`:
a directory of scripts you wrote, and a dispatcher that will only ever run those.

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

/mnt/user/appdata/docker_projects/                   the stacks
  EasyEdit-Photos/
  MusicScan/
  secrets/gh_pat_token                               mounted at /secrets (ro)
```

## Quick start

```bash
git clone https://github.com/ShadyHippo/DockerDeploy.git \
  /mnt/user/appdata/docker_projects/DockerDeploy
cd /mnt/user/appdata/docker_projects/DockerDeploy

chown root:root scripts
chmod 755 scripts
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
| `RUN_TIMEOUT` | `1800` | seconds before a script is killed |
| `LISTEN_HOST` | `0.0.0.0` | bind address |
| `LISTEN_PORT` | `9000` | port |
| `LOG_TAIL` | `8000` | characters of output returned to the caller |
| `PROJECTS_DIR` | `/mnt/user/appdata/docker_projects` | stacks, mounted at the same path (compose) |

## Reaching it from another container

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

No ports are published, so it is only reachable from containers on that network.

## Private registries

The token is **mounted, not copied**. Point `SECRETS_DIR` at the directory that
already holds it — the default is `/mnt/user/appdata/docker_projects/secrets`,
mounted read-only at `/secrets`:

```bash
chmod 600 /mnt/user/appdata/docker_projects/secrets/gh_pat_token
```

and in the script:

```bash
export DOCKER_CONFIG=/tmp/docker      # tmpfs: the login is not persisted
mkdir -p "$DOCKER_CONFIG"
tr -d '\n' < /secrets/gh_pat_token \
  | docker login ghcr.io -u <user> --password-stdin
```

Keeping `DOCKER_CONFIG` on `/tmp` means `docker login` writes its `config.json`
to memory, so the token is never copied into a second file on disk.

## Building

```bash
docker build -t ghcr.io/shadyhippo/dockerdeploy:latest .
# or daemonless:
buildah bud -t ghcr.io/shadyhippo/dockerdeploy:latest .
```

CI also builds and pushes `:latest` and a short-sha tag on every push to `main`.
