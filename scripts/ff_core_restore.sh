#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=/opt/ffactory
ENVF=$ROOT/.env
NET=ffactory_ffactory_net
STACK=$ROOT/stack
mkdir -p "$STACK"

# 1) تحميل .env لو موجود لتجنب unbound
[ -f "$ENVF" ] && set -a && . "$ENVF" && set +a || true
POSTGRES_USER=${POSTGRES_USER:-ffadmin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-ffpass}
POSTGRES_DB=${POSTGRES_DB:-ffactory}
REDIS_PASSWORD=${REDIS_PASSWORD:-ffredis}
NEO4J_AUTH=${NEO4J_AUTH:-neo4j/neo4jpass}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

# 2) شبكة Docker
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# 3) Compose للكور — بدون أي توسعات معقّدة
cat >"$STACK/docker-compose.core.yml"<<YML
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { ff_pg: {}, ff_minio: {}, ff_neo4j: {} }

services:
  db:
    image: postgres:16
    container_name: ffactory_db
    env_file: [ ../.env ]
    environment:
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
    image: minio/minio:RELEASE.2024-12-18T00-00-00Z
    container_name: ffactory_minio
    env_file: [ ../.env ]
    command: server /data --console-address ":9001"
    volumes: [ ff_minio:/data ]
    ports: [ "127.0.0.1:9000:9000", "127.0.0.1:9001:9001" ]
    networks: [ ffactory_ffactory_net ]
    # نترك الهيلث بسيط لتفادي اعتماد curl/bash داخل الصورة
    healthcheck:
      test: ["CMD-SHELL","printf '' >/dev/tcp/127.0.0.1/9000 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 40

  neo4j:
    image: neo4j:5.22
    container_name: ffactory_neo4j
    env_file: [ ../.env ]
    environment:
      - NEO4J_AUTH=${NEO4J_AUTH}
      - NEO4J_server_jvm_additional=-XX:+ExitOnOutOfMemoryError
      - NEO4J_PLUGINS=["apoc"]
    volumes: [ ff_neo4j:/data ]
    ports: [ "127.0.0.1:7474:7474", "127.0.0.1:7687:7687" ]
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      # نستخدم $$ للهروب حتى لا يتدخل compose، ويُنفّذ التوسّع داخل الحاوية
      test: ["CMD-SHELL","sh -lc 'cypher-shell -a bolt://localhost:7687 -u $${NEO4J_AUTH%%/*} -p $${NEO4J_AUTH#*/} \"RETURN 1\" | grep -q 1'"]
      interval: 15s
      timeout: 10s
      retries: 40
YML

# 4) إصلاح ملف ext الفارغ ليطابق المنافذ الحالية دون إعادة إنشاء
if [ ! -s "$STACK/docker-compose.apps.ext.yml" ]; then
  cat >"$STACK/docker-compose.apps.ext.yml"<<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { hashsets_data: {} }
services:
  vision-engine:
    container_name: ffactory_vision
    image: ffactory-vision-engine
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8081:8080" ]
  media-forensics:
    container_name: ffactory_media_forensics
    image: ffactory-media-forensics
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8082:8080" ]
  hashset-service:
    container_name: ffactory_hashset
    image: ffactory-hashset-service
    networks: [ ffactory_ffactory_net ]
    volumes: [ "hashsets_data:/data/hashsets" ]
    ports: [ "127.0.0.1:8083:8080" ]
YML
fi

# 5) تشغيل الكور
docker compose -f "$STACK/docker-compose.core.yml" up -d

# 6) انتظار أساسي
echo "[*] انتظار الخدمات الأساسية..."
sleep 10
docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 7) تحقق سريع للبوابات
for p in 5433 6379 7474 7687 9000 9001; do
  (echo >/dev/tcp/127.0.0.1/$p) >/dev/null 2>&1 && echo "[OK] port $p open" || echo "[WAIT] port $p closed"
done
