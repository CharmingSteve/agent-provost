ARG BASE_PYTHON_IMAGE=python:3.11-alpine@sha256:5f2c7aad5aa1aa37c8e023c8bdd40aab8d2caa9589a0d428662eadace011b9e0
#Base image needs  needs to be twice, here and in env.versions
# This Alpine is from https://hub.docker.com/layers/library/python/3.11-alpine3.23/images/sha256-d2f7cab9195aef6d63af382e070462cc8361b8d9478877a4eae7ff65ff8c7fb2 it is multiplatform 
# checkov:skip=CKV_DOCKER_7:base image is pinned to a digest via ARG default above
# hadolint ignore=DL3006
FROM ${BASE_PYTHON_IMAGE}

COPY hash-pip/requirements-runtime.txt /tmp/requirements-runtime.txt
# the Alpaca Mcp Server is installed with pip, its page is https://pypi.org/project/alpaca-mcp-server/ and https://github.com/alpacahq/alpaca-mcp-server
RUN apk upgrade --no-cache \
	&& pip install --no-cache-dir --require-hashes --no-deps -r /tmp/requirements-runtime.txt \
	&& pip install --no-cache-dir "alpaca-mcp-server==2.1.0" \
	&& rm -f /tmp/requirements-runtime.txt \
	&& adduser -D -u 10001 -s /bin/sh appuser \
	&& chown -R appuser:appuser /usr/local/lib/python3.11/site-packages

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
	CMD python -c "import socket; s = socket.create_connection(('127.0.0.1', 8088), 3); s.close()" || exit 1

# remove comment to trigger rebuild, or just add

