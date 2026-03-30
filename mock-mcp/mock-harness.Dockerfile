FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn mcp requests

COPY mock_api.py /app/mock_api.py
COPY mock_mcp.py /app/mock_mcp.py
