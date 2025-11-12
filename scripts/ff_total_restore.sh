#!/usr/bin/env bash
set -Eeuo pipefail

# -------- ثابتات --------
ROOT=/opt/ffactory
STACK=$ROOT/stack
BACKUPS=$ROOT/backups
ENVF=$ROOT/.env
NET=ffactory_ffactory_net
CORE=$STACK/docker-compose.core.clean.yml

log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
has(){ command -v "$1" >/dev/null 2>&1; }

# -------- أدوات --------
http_get(){
  local url="$1"
  if has curl; then curl -fsS --max-time 3 "$url"
  elif has wget; then wget -qO- "$url"
  else return 127; fi
}

wait_pg(){
  local tries=60
  while ((tries--)); do
    if docker exec ffactory_db pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

wait_redis(){
  local tries=60
  while ((tries--)); do
    if docker exec ffactory_redis sh -lc "redis-cli -a '$REDIS_PASSWORD' ping | grep -q PONG"; then return 0; fi
    sleep 2
  done
  return 1
}

wait_neo4j(){
  local tries=90
  while ((tries--)); do
    if http_get http://127.0.0.1:7474 >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

wait_minio(){
  local tries=90
  while ((tries--)); do
    if http_get http://127.0.0.1:9000/minio/health/ready >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# -------- تهيئة --------
install -d -m 755 "$STACK" "$BACKUPS"

# شبكة
docker network inspect "$NET" >/dev/null 2>&1 || { log "create network $NET"; docker network create "$NET" >/dev/null; }

# تحميل .env مع قيم افتراضية آمنة
[ -f "$ENVF" ] && set -a && . "$ENVF" && set +a || true
POSTGRES_USER=${POSTGRES_USER:-ffadmin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-ffpass}
POSTGRES_DB=${POSTGRES_DB:-ffactory}
REDIS_PASSWORD=${REDIS_PASSWORD:-ffredis}
NEO4J_AUTH=${NEO4J_AUTH:-neo4j/neo4jpass}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

# تثبيت لوكيـل افتراضي للنظام إن لزم
if has update-locale; then sudo update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8 >/dev/null 2>&1 || true; fi

# -------- ملف Compose نظيف للكور --------
log "write $CORE"
cat >"$CORE"<<YML
name: ffactory
networks:
  ffactory_ffactory_net: { external: true }
volumes:
  ff_pg: {}
  ff_minio: {}
  ff_neo4j: {}
services:
  db:
    image: postgres:16
    container_name: ffactory_db
    environment:
      LANG: C.UTF-8
      LC_ALL: C.UTF-8
      POSTGRES_USER: "${POSTGRES_USER}"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_DB: "${POSTGRES_DB}"
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - ff_pg:/var/lib/postgresql/data
    ports: [ "127.0.0.1:5433:5432" ]
    networks: [ ffactory_ffactory_net ]

  redis:
    image: redis:7
    container_name: ffactory_redis
    environment:
      LANG: C.UTF-8
      LC_ALL: C.UTF-8
    command: ["redis-server","--requirepass","${REDIS_PASSWORD}"]
    ports: [ "127.0.0.1:6379:6379" ]
    networks: [ ffactory_ffactory_net ]

  neo4j:
    image: neo4j:5
    container_name: ffactory_neo4j
    environment:
      LANG: C.UTF-8
      LC_ALL: C.UTF-8
      NEO4J_AUTH: "${NEO4J_AUTH}"
      server.config.strict_validation.enabled: "true"
    volumes:
      - ff_neo4j:/data
    ports: [ "127.0.0.1:7474:7474", "127.0.0.1:7687:7687" ]
    networks: [ ffactory_ffactory_net ]

  minio:
    image: minio/minio:latest
    container_name: ffactory_minio
    environment:
      MINIO_ROOT_USER: "${MINIO_ROOT_USER}"
      MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD}"
    command: ["server","/data","--console-address",":9001"]
    volumes: [ "ff_minio:/data" ]
    ports: [ "127.0.0.1:9000:9000", "127.0.0.1:9001:9001" ]
    networks: [ ffactory_ffactory_net ]
YML

# تحقق من صحة الـCompose
docker compose -f "$CORE" config >/dev/null

# -------- تطبيق --------
log "up core"
docker compose -f "$CORE" up -d

log "wait postgres"
wait_pg || { log "postgres not ready"; exit 1; }
log "wait redis"
wait_redis || { log "redis not ready"; exit 1; }
log "wait neo4j"
wait_neo4j || log "neo4j http not ready, continue"
log "wait minio"
wait_minio || log "minio not ready, continue"

# -------- استعادة DB تلقائيًا لو فارغ ووجد تفريغ --------
auto_restore_db(){
  # تحقّق أن الـDB لا يحتوي جداول مستخدمين
  local cnt
  cnt=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" ffactory_db \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
        "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');" 2>/dev/null | tr -d '[:space:]' || echo "0")
  if [[ "$cnt" != "0" ]]; then log "db not empty, skip restore"; return 0; fi

  # التقط أحدث ملف تفريغ
  local dump
  dump=$(ls -1t $BACKUPS/*.sql.gz $BACKUPS/*.sql 2>/dev/null | head -1 || true)
  [[ -z "$dump" ]] && dump=$(ls -1t /mnt/data/*.sql.gz /mnt/data/*.sql 2>/dev/null | head -1 || true)
  [[ -z "$dump" ]] && { log "no dump found, skip restore"; return 0; }

  log "restore from $dump"
  if [[ "$dump" == *.gz ]]; then
    gunzip -c "$dump" | docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" ffactory_db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
  else
    docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" ffactory_db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$dump"
  fi
  log "restore done"
}

auto_restore_db || true

# -------- ملخص --------
log "summary"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_ || true
log "[PG]" ; docker exec ffactory_db pg_isready -U "$POSTGRES_USER" || true
log "[REDIS]"; docker exec ffactory_redis sh -lc "redis-cli -a '$REDIS_PASSWORD' ping" || true
log "[NEO4J]"; http_get http://127.0.0.1:7474 >/dev/null && echo ok || echo fail
log "[MINIO]"; http_get http://127.0.0.1:9000/minio/health/ready >/dev/null && echo ok || echo fail

exit 0
