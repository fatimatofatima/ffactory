#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/ffactory/scripts/ff_00_env.sh

log "🧹 تنظيف الحاويات القديمة (ffactory_*)..."
OLD=$(docker ps -a --format '{{.Names}}' | grep '^ffactory_' || true)
if [ -n "$OLD" ]; then
  echo "$OLD" | xargs -r docker stop >/dev/null 2>&1 || true
  echo "$OLD" | xargs -r docker rm   >/dev/null 2>&1 || true
  log "✅ تم مسح الحاويات القديمة"
else
  log "ℹ️ مفيش حاويات قديمة"
fi
