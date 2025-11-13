#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/ffactory/stack
docker compose -f docker-compose.core.yml down
