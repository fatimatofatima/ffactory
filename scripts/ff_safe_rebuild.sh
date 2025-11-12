#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

# ثوابت
FF=/opt/ffactory
APPS=$FF/apps
STACK=$FF/stack
ENVF=$FF/.env
NET=ffactory_ffactory_net

install -d -m 755 "$APPS" "$STACK" "$FF/scripts" "$FF/data" "$FF/data/hashsets"

# بيئة مع افتراضات آمنة
[ -f "$ENVF" ] && set -a && . "$ENVF" && set +a || true
POSTGRES_USER=${POSTGRES_USER:-ffadmin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-ffpass}
POSTGRES_DB=${POSTGRES_DB:-ffactory}
NEO4J_USER=${NEO4J_USER:-neo4j}
NEO4J_PASSWORD=${NEO4J_PASSWORD:-neo4jpass}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

# أدوات منافذ
in_use(){ ss -ltn 2>/dev/null|awk '{print $4}'|sed -n 's/.*:\([0-9]\+\)$/\1/p'|grep -qx "$1" \
|| netstat -ltn 2>/dev/null|awk '{print $4}'|sed -n 's/.*:\([0-9]\+\)$/\1/p'|grep -qx "$1"; }
pick(){ p="$1"; while in_use "$p"; do p=$((p+1)); done; echo "$p"; }

VISION_PORT=${VISION_PORT:-$(pick 8081)}
MEDIA_PORT=${MEDIA_PORT:-$(pick 8082)}
HASHSET_PORT=${HASHSET_PORT:-$(pick 8083)}

# شبكة
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# ================= core compose نظيف =================
CORE_YML=$STACK/docker-compose.core.clean.yml
cat >"$CORE_YML"<<YML
version: "3.9"
name: ffactory
networks:
  default:
    external: true
    name: ffactory_ffactory_net
services:
  db:
    image: postgres:16
    container_name: ffactory_db
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes: [ "pgdata:/var/lib/postgresql/data" ]
    ports: [ "127.0.0.1:5433:5432" ]
    networks: [default]
  neo4j:
    image: neo4j:5.22
    container_name: ffactory_neo4j
    environment:
      NEO4J_AUTH: ${NEO4J_USER}/${NEO4J_PASSWORD}
    volumes: [ "neo4jdata:/data" ]
    ports: [ "127.0.0.1:7474:7474", "127.0.0.1:7687:7687" ]
    networks: [default]
  minio:
    image: minio/minio:latest
    container_name: ffactory_minio
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    command: server --console-address ":9001" /data
    volumes: [ "miniodata:/data" ]
    ports: [ "127.0.0.1:9000:9000", "127.0.0.1:9001:9001" ]
    networks: [default]
  redis:
    image: redis:7
    container_name: ffactory_redis
    networks: [default]
volumes: { pgdata: {}, neo4jdata: {}, miniodata: {} }
YML

log "[*] bring up core"
docker compose -f "$CORE_YML" up -d

# انتظار جاهزية المنافذ الحرجة
wait_port(){ h="$1"; p="$2"; t="${3:-60}"; while ! (echo > /dev/tcp/$h/$p) >/dev/null 2>&1; do
  t=$((t-1)); [ "$t" -le 0 ] && die "port $h:$p لم يجهز"; sleep 1; done; }
wait_port 127.0.0.1 5433 90
wait_port 127.0.0.1 7474 90
wait_port 127.0.0.1 9000 60

# ================= apps-ext نظيف =================
EXT_YML=$STACK/docker-compose.apps.ext.clean.yml
cat >"$EXT_YML"<<YML
version: "3.9"
name: ffactory
networks:
  default:
    external: true
    name: ffactory_ffactory_net
volumes: { hashsets_data: {} }
services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    networks: [default]
    ports: [ "127.0.0.1:${VISION_PORT}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40
  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory_media_forensics
    networks: [default]
    ports: [ "127.0.0.1:${MEDIA_PORT}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40
  hashset-service:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory_hashset
    environment:
      NSRL_DB_PATH: /data/hashsets/nsrl.sqlite
    volumes: [ "hashsets_data:/data/hashsets" ]
    networks: [default]
    ports: [ "127.0.0.1:${HASHSET_PORT}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

# إيقاف أي حاويات قديمة
docker rm -f ffactory_vision ffactory_media_forensics ffactory_hashset >/dev/null 2>&1 || true

log "[*] bring up apps-ext"
VISION_PORT="$VISION_PORT" MEDIA_PORT="$MEDIA_PORT" HASHSET_PORT="$HASHSET_PORT" \
docker compose -f "$EXT_YML" up -d --build

# انتظار الصحة HTTP
wait_http(){ url="$1"; t="${2:-120}"; until curl -fsS "$url" >/dev/null 2>&1; do
  t=$((t-1)); [ "$t" -le 0 ] && die "healthcheck فشل: $url"; sleep 1; done; }
wait_http "http://127.0.0.1:${VISION_PORT}/health" 180
wait_http "http://127.0.0.1:${MEDIA_PORT}/health" 180
wait_http "http://127.0.0.1:${HASHSET_PORT}/health" 180

log "[ok] جاهز"
echo "VISION  : http://127.0.0.1:${VISION_PORT}/health"
echo "MEDIA   : http://127.0.0.1:${MEDIA_PORT}/health"
echo "HASHSET : http://127.0.0.1:${HASHSET_PORT}/health"
