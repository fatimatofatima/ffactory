#!/usr/bin/env bash
set -Eeuo pipefail
STACK=/opt/ffactory/stack
cd "$STACK"

set +e
docker compose -p ffactory -f docker-compose.ultimate.yml -f docker-compose.override.yml config >/tmp/ffactory_compose_render.yaml 2>/tmp/ffactory_compose_err.txt
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo "compose config failed:"
  sed -n '1,200p' /tmp/ffactory_compose_err.txt
  exit 1
fi
echo "compose config OK → /tmp/ffactory_compose_render.yaml"

docker compose -p ffactory -f docker-compose.ultimate.yml -f docker-compose.override.yml down --remove-orphans || true
docker network rm ffactory_default 2>/dev/null || true
echo "preflight done."
