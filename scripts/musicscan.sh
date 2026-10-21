#!/bin/bash
# POST /run/musicscan
#
# Pulls the current image and recreates only what changed. Compose compares the
# image ID itself, so a run with no new image is a no-op.
set -euo pipefail

PROJECT=/mnt/user/appdata/docker_projects/MusicScan
MODE=pull   # pull = registry image, build = docker compose build

[ -d "$PROJECT" ] || { echo "no such project: $PROJECT" >&2; exit 1; }
cd "$PROJECT"
export DOCKER_CONFIG=/root/.docker

# private image: needs docker/ghcr.token (PAT with read:packages)
if [ -s /root/.docker/ghcr.token ]; then
    tr -d '\n' < /root/.docker/ghcr.token \
        | docker login ghcr.io -u ShadyHippo --password-stdin
fi

if [ "$MODE" = build ]; then
    docker compose build
else
    docker compose pull
fi

exec docker compose up -d
