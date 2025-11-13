#!/usr/bin/env bash
set -Eeuo pipefail
STACK=/opt/ffactory/stack
cd "$STACK"
docker compose -p ffactory -f docker-compose.ultimate.yml -f docker-compose.override.yml up -d --build --remove-orphans
sleep 10
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "logs: docker compose -p ffactory -f $STACK/docker-compose.ultimate.yml -f $STACK/docker-compose.override.yml logs -f --tail=100"
