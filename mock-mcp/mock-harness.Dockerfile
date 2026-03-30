FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN pip install --no-cache-dir \
    fastapi==0.135.2 \
    uvicorn==0.42.0 \
    "mcp==1.26.0" \
    requests==2.33.0

COPY mock_api.py mock_mcp.py ./

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

USER appuser

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD python -c "import socket; s=socket.create_connection(('localhost', 8088), timeout=5); s.close()"
