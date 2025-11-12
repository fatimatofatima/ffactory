#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/ffactory/scripts/ff_health_lib.sh

declare -a ARGS=()
# اجمع كل docker-compose*.yml بترتيب ثابت
while IFS= read -r -d '' f; do ARGS+=(-f "$f"); done < <(find /opt/ffactory/stack -maxdepth 1 -type f -name 'docker-compose*.yml' -print0 | sort -z)
# أضف health إن وُجد
[[ -f /opt/ffactory/stack/docker-compose.health.yml ]] && ARGS+=(-f /opt/ffactory/stack/docker-compose.health.yml)

# لا تخلط COMPOSE_IGNORE_ORPHANS مع --remove-orphans
COMPOSE_IGNORE_ORPHANS=1 dcf "${ARGS[@]}" down -v || true
COMPOSE_IGNORE_ORPHANS=1 dcf "${ARGS[@]}" build --no-cache
COMPOSE_IGNORE_ORPHANS=1 dcf "${ARGS[@]}" up -d
