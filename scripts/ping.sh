#!/bin/bash
# Connectivity check: reports the script environment and exits.
# Call with: curl -XPOST http://docker-deploy:9000/run/ping
set -uo pipefail

echo "script:     $0"
echo "user:       $(id -un) (uid=$(id -u))"
echo "pwd:        $(pwd)"
echo "argc:       $#"
echo "docker:     $(docker version --format '{{.Server.Version}}' 2>&1 | head -1)"
echo "projects:   $(ls -1 /mnt/user/appdata/docker-projects 2>/dev/null | head -5 | tr '\n' ' ')"
echo "scripts:    $(ls -1 /scripts/*.sh 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
