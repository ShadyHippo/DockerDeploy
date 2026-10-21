#!/bin/bash
# POST /run/acnh   (the ACNH stack lives in docker_projects/IslanderGiftTracker)
#
# Rebuilds from the checked-out sources and recreates only what changed.
# If this stack ever gets a registry image, set MODE=pull.
set -euo pipefail

PROJECT=/mnt/user/appdata/docker_projects/IslanderGiftTracker
MODE=build   # pull = registry image, build = docker compose build

[ -d "$PROJECT" ] || { echo "no such project: $PROJECT" >&2; exit 1; }
cd "$PROJECT"
export DOCKER_CONFIG=/root/.docker

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
