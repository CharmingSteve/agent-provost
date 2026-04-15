ARG BASE_PYTHON_IMAGE=python:3.11-alpine@sha256:f07e2ace46f560f09a6eeec7b4913b80ee99546e749ef82342a419a326620856
FROM ${BASE_PYTHON_IMAGE}

RUN apk upgrade --no-cache \
	&& pip install --no-cache-dir "uv==0.8.16" \
	&& pip install --no-cache-dir "alpaca-mcp-server==2.0.0" \
	&& pip install --no-cache-dir "pip==24.0" "setuptools==82.0.1" "wheel==0.46.3" "jaraco.context==6.1.2" \
	&& adduser -D -u 10001 -s /bin/sh appuser \
	&& chown -R appuser:appuser /usr/local/lib/python3.11/site-packages

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
	CMD python -c "import socket; s = socket.create_connection(('127.0.0.1', 8088), 3); s.close()" || exit 1
