#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo "[ff/start] $*"; }

STACK=/opt/ffactory/stack
P="-p ffactory -f $STACK/docker-compose.yml -f $STACK/docker-compose.depends.yml -f $STACK/docker-compose.db-env.yml -f $STACK/docker-compose.neo4j-env.yml"

log "bring up core infra: db + neo4j + redis + minio"
docker compose $P up -d db neo4j redis minio

log "wait for health"
for s in ffactory_db ffactory_neo4j ffactory_redis ffactory_minio; do
  for i in {1..40}; do
    st="$(docker inspect -f '{{.State.Health.Status}}' "$s" 2>/dev/null || echo starting)"
    [ "$st" = "healthy" ] && break
    sleep 3
  done
done

log "internal checks from a temp net ns"
docker run --rm --network ffactory_ffactory_net bash:5 bash -lc '
  set -e
  python - <<PY
import socket,sys
for host,port in [("db",5432),("neo4j",7687),("ffactory_minio",9000),("ffactory_redis",6379)]:
    s=socket.socket(); s.settimeout(3); s.connect((host,port)); s.close()
print("TCP OK to db/neo4j/minio/redis")
PY
'
log "now bring up app services if defined"
docker compose $P up -d api_gateway investigation_api correlation_engine frontend-dashboard || true

log "probe neo4j bolt"
docker exec -i ffactory_neo4j cypher-shell -u neo4j -p 'Forensic123!' 'RETURN 1;' || true

log "done."
