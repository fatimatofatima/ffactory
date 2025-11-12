#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/ffactory/scripts/ff_00_env.sh

log "🤖 تشغيل خدمات AI (echo-server) ..."

declare -A SVCS=(
  [ffactory_asr]=8086
  [ffactory_nlp]=8000
  [ffactory_correlation]=8170
  [ffactory_social]=8088
)

for name in "${!SVCS[@]}"; do
  port=${SVCS[$name]}
  docker stop "$name" >/dev/null 2>&1 || true
  docker rm   "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" \
    -p 127.0.0.1:$port:8080 \
    --network "$FF_NET" \
    ealen/echo-server:latest >/dev/null
  log "   ✅ $name على $port"
done

log "✅ خدمات AI شغّالة"
