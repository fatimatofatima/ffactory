#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/ffactory/stack
echo "== ps =="; docker compose -f docker-compose.core.yml ps
echo "== health =="
for c in ffactory_db ffactory_ollama ffactory_asr ffactory_echo; do
  printf "%-18s %s\n" "$c" "$(docker inspect -f '{{.State.Health.Status}}' $c 2>/dev/null || echo 'n/a')"
done
echo "== logs:db (last 60) =="; docker logs --tail=60 ffactory_db 2>/dev/null || true
