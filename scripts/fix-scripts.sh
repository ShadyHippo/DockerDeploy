#!/bin/bash
# POST /run/fix-scripts
#
# Repairs the allowlist's permissions after an edit or a git pull.
#
# Why this exists: /mnt/user on Unraid is shfs, which hands out 775/777 instead
# of 755 when a file is rewritten. The sidecar refuses any script that is
# group/other writable, so an edited script silently stops being callable.
#
# This script only chowns to root and chmods 755. It never creates or edits a
# script - the allowlist stays whatever the operator wrote.
#
# The /scripts mount is read-only by design, so the changes go through the
# projects mount, which is the same directory on the host.
set -euo pipefail

HOST_DIR="${SCRIPTS_HOST_DIR:-${PROJECTS_DIR:-/mnt/user/appdata/docker_projects}/DockerDeploy/scripts}"

if [ ! -d "$HOST_DIR" ]; then
    echo "not found: $HOST_DIR" >&2
    echo "set SCRIPTS_HOST_DIR to the host path of the allowlist" >&2
    exit 1
fi

if ! touch "$HOST_DIR/.permcheck" 2>/dev/null; then
    echo "cannot write $HOST_DIR" >&2
    echo "is PROJECTS_DIR mounted read-write in compose.yaml?" >&2
    exit 1
fi
rm -f "$HOST_DIR/.permcheck"

shopt -s nullglob
files=("$HOST_DIR"/*.sh)
if [ "${#files[@]}" -eq 0 ]; then
    echo "no .sh files in $HOST_DIR"
    exit 1
fi

chown root:root "${files[@]}"
chmod 755 "${files[@]}"

echo "fixed ${#files[@]} script(s) in $HOST_DIR:"
ls -l "${files[@]}"
