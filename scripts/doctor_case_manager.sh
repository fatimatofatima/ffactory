#!/usr/bin/env bash
set -Eeuo pipefail
C="ffactory_case_manager"
STACK="/opt/ffactory/stack"
COMPOSE="$STACK/docker-compose.complete.yml"

echo "🔎 Detecting case-manager port from logs..."
PORT="$(docker logs "$C" 2>&1 | grep -oE '0\.0\.0\.0:[0-9]+' | tail -1 | cut -d: -f2 || true)"
[ -z "${PORT:-}" ] && PORT="8140"   # fallback

echo "➡️  Trying health on localhost:$PORT ..."
if docker compose -f "$COMPOSE" exec -T case-manager sh -lc "curl -fsS http://127.0.0.1:$PORT/health >/dev/null"; then
  echo "✅ HEALTH OK on :$PORT"
else
  echo "❌ Health failed on :$PORT. Checking env..."
  docker compose -f "$COMPOSE" exec -T case-manager sh -lc 'env | grep -E "PGUSER|PGPASSWORD|PGDB|DATABASE_URL" || true'
  echo "↻ Restarting case-manager..."
  docker compose -f "$COMPOSE" up -d --build case-manager
  sleep 5
  docker compose -f "$COMPOSE" exec -T case-manager sh -lc "curl -fsS http://127.0.0.1:$PORT/health || true"
fi
