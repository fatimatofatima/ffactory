#!/usr/bin/env bash
set -uo pipefail
ROOT=/opt/ffactory
ENVF=$ROOT/.env
STACK=$ROOT/stack/docker-compose.core.yml
PW="Aa100200"
NET=ffactory_default
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

set -a; . "$ENVF"; set +a || true

# تأكيد التشغيل
docker compose -f "$STACK" up -d --wait >/dev/null || true

DB=$(docker compose -f "$STACK" ps -q db || true)
RD=$(docker compose -f "$STACK" ps -q redis || true)
NJ=$(docker compose -f "$STACK" ps -q neo4j || true)
MN=$(docker compose -f "$STACK" ps -q minio || true)

log "neo4j: constraints"
[ -n "$NJ" ] && docker exec -i "$NJ" cypher-shell -u neo4j -p "$PW" <<'CYPH' || true
CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;
CREATE CONSTRAINT file_sha IF NOT EXISTS FOR (f:File)   REQUIRE f.sha256 IS UNIQUE;
CREATE INDEX event_ts IF NOT EXISTS FOR (e:Event) ON (e.ts);
CYPH

log "minio: create user+policies+buckets"
docker run --rm --network="$NET" minio/mc sh -c "
  mc alias set local http://minio:9000 ${MINIO_ROOT_USER:-ffroot} ${MINIO_ROOT_PASSWORD:-$PW} &&
  mc admin user add local ffactory $PW || true &&
  mc admin policy attach local readwrite --user ffactory || true &&
  mc mb -p local/raw || true &&
  mc mb -p local/decoded || true &&
  mc mb -p local/reports || true
" || true

log "done"
