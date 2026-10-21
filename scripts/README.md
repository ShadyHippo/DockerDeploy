# Deploy scripts

Every `*.sh` file in this directory is callable by name. Nothing else is.

```
POST /run/easyedit   ->   /scripts/easyedit.sh
```

Adding or removing a script takes effect on the next request. There is no
registry, no restart, no registration step.

## Requirements

Each script must be:

- a **regular file** (no symlinks),
- owned by **root**,
- **executable** by its owner,
- **not writable** by group or others,

and the directory itself must be root-owned and not group/other writable.

From the checkout root:

```bash
chown root:root scripts scripts/*.sh
chmod 755 scripts scripts/*.sh
```

This matters on Unraid: files under `/mnt/user` are often `nobody:nobody`, so
"owner writable" would mean any SMB user could edit a script that root then
executes. The server refuses such a file rather than run it.

## Contract

- **No arguments are passed.** `$#` is always 0.
- **Fixed environment**: `PATH`, `HOME=/root`, `DOCKER_CONFIG=/root/.docker`,
  `LANG`. Nothing from the caller is inherited.
- **Working directory is `/`.** `cd` where you need to go.
- **stdin is `/dev/null`**, so nothing can be piped in.
- **stdout and stderr are returned** to the caller (last 8 KB) with the exit
  code. `0` means success.

Only what is mounted into the container exists: `/scripts`, the projects
directory (by default `/mnt/user/appdata/docker_projects`, at the same path as on
the host) and `/root/.docker`. Host-only things (`systemctl`, `mdcmd`, `/boot`,
the host's own `/root`) are not there.

## Template

```bash
#!/bin/bash
set -euo pipefail

PROJECT=/mnt/user/appdata/docker_projects/Example
export DOCKER_CONFIG=/tmp/docker
mkdir -p "$DOCKER_CONFIG"

# private images only
if [ -s /secrets/gh_pat_token ]; then
  tr -d '\n' < /secrets/gh_pat_token \
    | docker login ghcr.io -u <user> --password-stdin >/dev/null
fi

cd "$PROJECT"
mapfile -t images < <(docker compose config --images)

before=()
for img in "${images[@]}"; do
  before+=("$(docker image inspect "$img" --format '{{.Id}}' 2>/dev/null || true)")
done

docker compose pull -q

changed=0
for i in "${!images[@]}"; do
  after=$(docker image inspect "${images[$i]}" --format '{{.Id}}' 2>/dev/null || true)
  [ "${before[$i]}" != "$after" ] && changed=1
done

if [ "$changed" -eq 0 ]; then
  echo "no new image"
  exit 0
fi

for img in "${images[@]}"; do
  docker tag "$img" "${img%:*}:previous" 2>/dev/null || true
done

docker compose up -d
echo "updated"
```

`ping.sh` is a safe one to keep: it reports the script's view of the world
without touching any stack.
