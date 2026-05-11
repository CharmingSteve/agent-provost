ARG BASE_PYTHON_IMAGE=python:3.11-alpine@sha256:f07e2ace46f560f09a6eeec7b4913b80ee99546e749ef82342a419a326620856
# checkov:skip=CKV_DOCKER_7:base image is pinned to a digest via ARG default above
# hadolint ignore=DL3006
# trigger-rebuild: four-fixes-task2
FROM ${BASE_PYTHON_IMAGE}

COPY hash-pip/requirements-runtime.txt /tmp/requirements-runtime.txt

RUN apk upgrade --no-cache \
	&& pip install --no-cache-dir --require-hashes --no-deps -r /tmp/requirements-runtime.txt \
	&& pip install --no-cache-dir "alpaca-mcp-server==2.0.1" \
	&& rm -f /tmp/requirements-runtime.txt \
	&& adduser -D -u 10001 -s /bin/sh appuser \
	&& chown -R appuser:appuser /usr/local/lib/python3.11/site-packages

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
	CMD python -c "import socket; s = socket.create_connection(('127.0.0.1', 8088), 3); s.close()" || exit 1
# trigger build please
