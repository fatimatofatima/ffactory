#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/ffactory/scripts/ff_00_env.sh

log "🔍 فحص البورتات ..."
PORTS="8081 8082 8083 8086 8000 8170 8088 5433 6379 7474 9000 9001"
for p in $PORTS; do
  if nc -z 127.0.0.1 "$p" >/dev/null 2>&1; then
    log "   ✅ Port $p مفتوح"
  else
    log "   ❌ Port $p مقفول"
  fi
done

log "🐳 الحاويات:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_ || true
