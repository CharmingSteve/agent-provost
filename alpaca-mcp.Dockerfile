FROM python:3.11-slim@sha256:9358444059ed78e2975ada2c189f1c1a3144a5dab6f35bff8c981afb38946634

RUN pip install --no-cache-dir "alpaca-mcp-server==2.0.0" \
	&& pip install --no-cache-dir --upgrade pip setuptools wheel "jaraco.context" \
		&& useradd --create-home --uid 10001 --shell /bin/sh appuser \
		&& chown -R appuser:appuser /usr/local/lib/python3.11/site-packages

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
	CMD python -c "import socket; s = socket.create_connection(('127.0.0.1', 8088), 3); s.close()" || exit 1
