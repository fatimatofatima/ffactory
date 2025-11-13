#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/ffactory/stack
export $(grep -v '^#' /opt/ffactory/.env | xargs -d '\n')
docker compose -f docker-compose.core.yml up -d
docker compose -f docker-compose.core.yml ps
if [ -f /opt/secure/smart.env ]; then
  set -a; . /opt/secure/smart.env; set +a
fi
