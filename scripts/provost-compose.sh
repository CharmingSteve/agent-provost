#!/bin/bash
cd /opt/agent-provost && docker compose --env-file .env.versions "$@"
