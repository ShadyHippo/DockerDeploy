#!/bin/bash
# POST /run/codecontainer
#
# Pulls ghcr.io/shadyhippo/codecontainer and recreates the container.
#
# SAFE BY CONSTRUCTION: this never runs git and never writes to compose.yaml.
# It only reads that file (docker compose config/pull/up) and acts on the
# daemon. No pull, checkout or rsync in here, so it cannot overwrite your
# compose or your checkout.
#
# Expect this call to kill the agent session that made it: the container it is
# running in gets recreated. T3 reconnects; the in-flight turn does not survive.
set -euo pipefail

PROJECT=/mnt/user/appdata/docker_projects/CodeContainer
MODE=pull   # pull = registry image. build would rebuild from source (slow).

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
