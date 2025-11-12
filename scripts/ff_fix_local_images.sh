#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

# الصور اللي انت بنيتها محليًا
PAIRS=(
  "ffactory/vision-engine:local|ffactory/vision-engine:latest"
  "ffactory/media-forensics:local|ffactory/media-forensics:latest"
  "ffactory/hashset-service:local|ffactory/hashset-service:latest"
)

for pair in "${PAIRS[@]}"; do
  src="${pair%%|*}"
  dst="${pair##*|}"

  if docker images -q "$src" >/dev/null 2>&1 && [ -n "$(docker images -q "$src")" ]; then
    log "tag $src -> $dst"
    docker tag "$src" "$dst"
  else
    log "⚠️ الصورة $src مش موجودة محلي، هنعدّيها"
  fi
done

log "📦 نرفع الـ stack بالـ override"
cd /opt/ffactory

docker compose \
  -f stack/docker-compose.core.yml \
  -f stack/docker-compose.apps.yml \
  -f stack/docker-compose.override.yml \
  up -d

log "✅ done"
