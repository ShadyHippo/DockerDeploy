FROM docker:29-cli

# bash for the deploy scripts, python3 for the dispatcher, the compose plugin
# and jq because scripts tend to want them.
RUN apk add --no-cache python3 bash jq docker-cli-compose

WORKDIR /app
COPY server.py /app/server.py

# Mount point for secrets (the container root is read-only at runtime, so the
# target directory has to exist in the image).
RUN mkdir -p /secrets

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    SCRIPT_DIR=/scripts \
    RUN_TIMEOUT=1800

EXPOSE 9000
ENTRYPOINT ["python3", "/app/server.py"]
