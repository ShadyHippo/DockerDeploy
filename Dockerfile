FROM docker:29-cli

# bash for the deploy scripts, python3 for the dispatcher, the compose plugin,
# jq because scripts tend to want them, and git so a build stack can pull its
# own checkout before `docker compose build` — the projects mount is rw for
# exactly that. ca-certificates is listed so git trusts HTTPS remotes.
RUN apk add --no-cache python3 bash jq docker-cli-compose git ca-certificates

WORKDIR /app
COPY server.py /app/server.py

# GIT_CONFIG_GLOBAL: the container root is read-only, so the default
# ~/.gitconfig cannot be written; point git's global config at the tmpfs the
# compose file already provides. Without it every
# `git config --global --add safe.directory <repo>` aborts under `set -e`.
# GIT_TERMINAL_PROMPT: a private or mistyped remote must fail at once instead
# of waiting on a credential prompt that can never be answered (stdin is
# /dev/null) until RUN_TIMEOUT fires.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    SCRIPT_DIR=/scripts \
    RUN_TIMEOUT=1800 \
    GIT_CONFIG_GLOBAL=/tmp/.gitconfig \
    GIT_TERMINAL_PROMPT=0

EXPOSE 9000
ENTRYPOINT ["python3", "/app/server.py"]
