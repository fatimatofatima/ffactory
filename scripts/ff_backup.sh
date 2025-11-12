#!/usr/bin/env bash
set -Eeuo pipefail
FF="/opt/ffactory"
STACK="$FF/stack"
ENV_FILE="$STACK/.env"
BACK="$FF/backups"
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACK"
set -a; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a

log(){ echo "[$(date +%F\ %T)] $*"; }

# 1) DB dump
DB_FILE="$BACK/db_${PGDB:-ffactory}_$TS.sql.gz"
log "Dump Postgres -> $DB_FILE"
docker exec ffactory_db pg_dump -U "${PGUSER:-forensic}" -d "${PGDB:-ffactory}" | gzip -9 > "$DB_FILE"

# 2) .env snapshot
cp -f "$ENV_FILE" "$BACK/env_$TS"

# 3) Volumes snapshot (project-prefixed)
vol() { docker volume ls --format '{{.Name}}' | grep -E '^ffactory_' | grep "$1" || true; }

for v in postgres_data redis_data neo4j_data minio_data ollama_data backup_data case_data; do
  VNAME=$(vol "$v")
  [ -z "$VNAME" ] && continue
  OUT="$BACK/vol_${v}_$TS.tgz"
  log "Archiving volume: $VNAME -> $OUT"
  docker run --rm -v "$VNAME":/v -v "$BACK":/o alpine sh -lc "cd /v && tar czf /o/$(basename "$OUT") ."
done

# 4) تنظيف (احتفظ بآخر 7 أيام)
find "$BACK" -type f -mtime +7 -delete || true
log "Backup done."
