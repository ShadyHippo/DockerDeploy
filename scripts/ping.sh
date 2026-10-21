#!/bin/bash
# Connectivity check: reports the script environment and exits.
# Call with: curl -XPOST http://docker-deploy:9000/run/ping
set -uo pipefail

PROJECTS="${PROJECTS_DIR:-/mnt/user/appdata/docker_projects}"

echo "script:     $0"
echo "user:       $(id -un) (uid=$(id -u))"
echo "pwd:        $(pwd)"
echo "argc:       $#"
echo "docker:     $(docker version --format '{{.Server.Version}}' 2>&1 | head -1)"
echo "hostname:   $(hostname)"

echo "mounts:"
for p in /scripts "$PROJECTS" /secrets /root/.docker; do
    if [ ! -e "$p" ]; then
        echo "  $p: MISSING (check the volume in compose.yaml)"
        continue
    fi
    n=$(ls -A "$p" 2>/dev/null | wc -l)
    echo "  $p: present, $n entr$( [ "$n" -eq 1 ] && echo y || echo ies)"
    if [ "$n" -gt 0 ] && [ "$n" -le 8 ]; then
        ls -A "$p" 2>/dev/null | sed 's/^/    - /'
    fi
done
