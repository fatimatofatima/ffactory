#!/usr/bin/env bash
set -uo pipefail
ROOT=/opt/ffactory
STACK=$ROOT/stack/docker-compose.core.yml
PW="Aa100200"
echo "[*] ps"
docker compose -f "$STACK" ps
echo
echo "[*] health cmds"
DB=$(docker compose -f "$STACK" ps -q db || true)
RD=$(docker compose -f "$STACK" ps -q redis || true)
NJ=$(docker compose -f "$STACK" ps -q neo4j || true)
MN=$(docker compose -f "$STACK" ps -q minio || true)
[ -n "$DB" ] && docker exec "$DB" pg_isready -U ffactory -d ffactory || true
[ -n "$RD" ] && docker exec "$RD" redis-cli -a "$PW" ping || true
[ -n "$NJ" ] && docker exec "$NJ" cypher-shell -u neo4j -p "$PW" 'RETURN 1;' || true
curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null && echo "minio: ready" || echo "minio: not ready"

echo
echo "[*] last logs if unhealthy"
for s in neo4j minio; do
  id=$(docker compose -f "$STACK" ps -q $s || true)
  [ -n "$id" ] || continue
  hs=$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo "none")
  if [ "$hs" != "healthy" ]; then
    echo "--- logs <$s> ---"; docker compose -f "$STACK" logs --tail=120 $s
  fi
done
