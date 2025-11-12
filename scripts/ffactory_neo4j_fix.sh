#!/usr/bin/env bash
set -Eeuo pipefail

OPS=/opt/ffactory/stack/docker-compose.ops.yml
PROJ=ffactory
NET=ffactory_default

log(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }

log "Patch compose (NEO4J_PLUGINS)"
sed -i 's/NEO4JLABS_PLUGINS/NEO4J_PLUGINS/g' "$OPS" || true

log "Find containers conflicting with ports 7474/7687"
CONFLICTS=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' | awk '/7474|7687/ {print $1}' | sort -u)
if [ -n "$CONFLICTS" ]; then
  log "Stopping: $CONFLICTS"
  docker stop $CONFLICTS >/dev/null 2>&1 || true
  log "Removing: $CONFLICTS"
  docker rm $CONFLICTS   >/dev/null 2>&1 || true
else
  log "No conflicting containers"
fi

log "Fix neo4j volume ownership (if needed)"
VOL=$(docker volume inspect ${PROJ}_neo4j_data -f '{{.Mountpoint}}' 2>/dev/null || true)
if [ -n "$VOL" ] && [ -d "$VOL" ]; then
  chown -R 7474:7474 "$VOL" || true
fi

log "Up neo4j"
docker compose -p "$PROJ" -f "$OPS" up -d neo4j

log "Wait for neo4j UI"
for i in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:7474 >/dev/null 2>&1; then
    echo "✅ Neo4j UI responding"
    break
  fi
  sleep 1
done

log "Up dependent apps (ingest-gateway, graph-writer)"
docker compose -p "$PROJ" -f "$OPS" up -d ingest-gateway graph-writer

echo
echo "=== Ops Status ==="
docker compose -p "$PROJ" -f "$OPS" ps

if ! curl -fsS http://127.0.0.1:7474 >/dev/null 2>&1; then
  echo
  echo "---- neo4j logs (last 200) ----"
  docker logs --tail 200 ${PROJ}-neo4j-1 || true
fi

echo
echo "Done."
