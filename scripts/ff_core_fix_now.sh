#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=/opt/ffactory
STACK=$ROOT/stack
ENVF=$ROOT/.env
NET=ffactory_ffactory_net

# 0) فك القفل عن ملفات الـYAML إن وُجد
chattr -i "$STACK"/*.yml 2>/dev/null || true

# 1) تحميل .env بأمان مع قيم افتراضية
[ -f "$ENVF" ] && set -a && . "$ENVF" && set +a || true
POSTGRES_USER=${POSTGRES_USER:-ffadmin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-ffpass}
POSTGRES_DB=${POSTGRES_DB:-ffactory}
REDIS_PASSWORD=${REDIS_PASSWORD:-ffredis}
NEO4J_AUTH=${NEO4J_AUTH:-neo4j/neo4jpass}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

# 2) إنشاء الشبكة لو مفقودة
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# 3) كتابة core compose نظيف بدون healthcheck معقد
cat >"$STACK/docker-compose.core.yml" <<YML
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { ff_pg: {}, ff_minio: {}, ff_neo4j: {} }

services:
  db:
    image: postgres:16
    container_name: ffactory_db
    env_file: [ ../.env ]
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_INITDB_ARGS=--data-checksums
    volumes: [ ff_pg:/var/lib/postgresql/data ]
    ports: [ "127.0.0.1:5433:5432" ]
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U $$POSTGRES_USER"]
      interval: 10s
      timeout: 5s
      retries: 30

  redis:
    image: redis:7
    container_name: ffactory_redis
    env_file: [ ../.env ]
    command: ["redis-server","--requirepass","${REDIS_PASSWORD}"]
    ports: [ "127.0.0.1:6379:6379" ]
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      test: ["CMD-SHELL","redis-cli -a $$REDIS_PASSWORD ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 30

  minio:
    image: minio/minio:latest
    container_name: ffactory_minio
    env_file: [ ../.env ]
    environment:
      - MINIO_ROOT_USER=${MINIO_ROOT_USER}
      - MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
    command: server /data --console-address ":9001"
    volumes: [ ff_minio:/data ]
    ports: [ "127.0.0.1:9000:9000", "127.0.0.1:9001:9001" ]
    networks: [ ffactory_ffactory_net ]

  neo4j:
    image: neo4j:5.22
    container_name: ffactory_neo4j
    env_file: [ ../.env ]
    environment:
      - NEO4J_AUTH=${NEO4J_AUTH}
      - NEO4J_PLUGINS=["apoc"]
      - NEO4J_server_jvm_additional=-XX:+ExitOnOutOfMemoryError
    volumes: [ ff_neo4j:/data ]
    ports: [ "127.0.0.1:7474:7474", "127.0.0.1:7687:7687" ]
    networks: [ ffactory_ffactory_net ]
YML

# 4) تشغيل الكور
docker compose -f "$STACK/docker-compose.core.yml" up -d

# 5) فحص سريع للمنافذ
echo; echo "[*] Ports:"
for p in 5433 6379 7474 7687 9000 9001; do
  (echo >/dev/tcp/127.0.0.1/$p) >/dev/null 2>&1 && echo "open :$p" || echo "wait :$p"
done

# 6) عرض الحالة
echo; echo "[*] Containers:"
docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
