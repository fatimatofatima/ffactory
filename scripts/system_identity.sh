#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/ffactory/scripts/ff_lib.sh

FF=/opt/ffactory
STACK=$FF/stack
LOGS=$FF/logs
COMPOSE="$(detect_compose)"
load_env

echo "FFactory System Identity"
echo "========================"
echo -e "\nBASIC:"
echo " Path: $FF"
echo " Compose: ${COMPOSE:-none}"
echo " Env: $ENV_FILE"
echo " Timestamp: $(date -Iseconds)"

echo -e "\nFILES:"
find "$FF" -type f \( -name "*.yml" -o -name "*.yaml" -o -name "*.sh" -o -name "*.py" -o -name ".env" \) \
  -printf " %p\t%TY-%Tm-%Td %TH:%TM\t%k KB\n" 2>/dev/null | head -30

echo -e "\nSERVICES:"
if command -v docker >/dev/null 2>&1; then
  docker ps --filter "name=ffactory" --format " {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  echo -e "\nIMAGES:"
  docker images --format " {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep -E '^ffactory-|^neo4j|^redis' || true
fi

echo -e "\nCONFIG SNAPSHOT:"
[[ -f "$ENV_FILE" ]] && grep -E '^(PG|REDIS|NEO4J|MINIO|FRONTEND|API|GRAFANA)_' "$ENV_FILE" | head -20 || echo " no .env"

echo -e "\nHEALTH:"
if [[ -n "${COMPOSE:-}" && -f "$COMPOSE" && $(command -v docker) ]]; then
  total=$(docker ps --filter "name=ffactory" --format '{{.ID}}' | wc -l | tr -d ' ')
  healthy=$(docker ps --filter "name=ffactory" --filter "health=healthy" --format '{{.ID}}' | wc -l | tr -d ' ')
  echo " $healthy/$total healthy"
else
  echo " compose not found or docker unavailable"
fi

echo -e "\nDEPENDENCIES:"
if [[ -n "${COMPOSE:-}" && -f "$COMPOSE" ]]; then
  awk '
    $1=="services:"{in_s=1}
    in_s && /depends_on:/{svc=last; dep=1; next}
    in_s && /^[[:space:]]*[a-zA-Z0-9_-]+:/{last=$1; gsub(":","",last)}
    dep && /^[[:space:]]*-[[:space:]]*/{gsub("-","");gsub(":","");print " " svc " -> " $1}
    dep && !/^[[:space:]]*-[[:space:]]*/{dep=0}
  ' "$COMPOSE"
else
  echo " none"
fi

echo -e "\nNETWORK:"
(command -v docker >/dev/null 2>&1 && docker network ls --format " {{.Name}}" | grep ffactory) || echo " no ffactory network or docker unavailable"

echo -e "\nDONE"
