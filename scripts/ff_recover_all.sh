#!/usr/bin/env bash
set -Eeuo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

ROOT=/opt/ffactory
STACK=$ROOT/stack
BACK=$ROOT/backups
ENVF=$ROOT/.env
NET=ffactory_ffactory_net

log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

# 0) أساسيات
apt-get update -y
apt-get install -y curl jq unzip rsync tar locales ca-certificates >/dev/null
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >>/etc/locale.gen || true
locale-gen en_US.UTF-8 >/dev/null || true
update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8 >/dev/null || true

install -d -m 755 "$STACK" "$ROOT/scripts" "$BACK" "$ROOT/apps" "$ROOT/data" "$ROOT/logs" "$ROOT/audit" "$ROOT/volumes"

# 1) .env إن لم يوجد أو ناقص
[ -f "$ENVF" ] || install -m 600 /dev/null "$ENVF"
add(){ grep -q "^$1=" "$ENVF" || printf "%s=%s\n" "$1" "$2" >>"$ENVF"; }
add POSTGRES_USER ffadmin
add POSTGRES_PASSWORD ffpass
add POSTGRES_DB ffactory
add REDIS_PASSWORD ffredis
add NEO4J_AUTH neo4j/neo4jpass
add MINIO_ROOT_USER minioadmin
add MINIO_ROOT_PASSWORD minioadmin

# 2) شبكة
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# 3) كتابة Compose نظيف للـcore فقط
cat >"$STACK/docker-compose.core.yml"<<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { ff_pg: {}, ff_minio: {}, ff_neo4j: {} }

services:
  db:
    image: postgres:16
    container_name: ffactory_db
    env_file: [ ../.env ]
    environment:
      LANG: C.UTF-8
      LC_ALL: C.UTF-8
      POSTGRES_INITDB_ARGS: --data-checksums
    volumes: [ ff_pg:/var/lib/postgresql/data ]
    ports: [ "127.0.0.1:5433:5432" ]
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U $$POSTGRES_USER"]
      interval: 10s
      timeout: 5s
      retries: 60

  redis:
    image: redis:7
    container_name: ffactory_redis
    command: ["redis-server","--requirepass","${REDIS_PASSWORD}"]
    env_file: [ ../.env ]
    ports: [ "127.0.0.1:6379:6379" ]
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      test: ["CMD","redis-cli","-a","${REDIS_PASSWORD}","PING"]
      interval: 10s
      timeout: 5s
      retries: 60

  neo4j:
    image: neo4j:5.23
    container_name: ffactory_neo4j
    env_file: [ ../.env ]
    environment:
      NEO4J_AUTH: ${NEO4J_AUTH}
      NEO4J_server_config_strict__validation_enabled: "false"
      NEO4J_server_http_listen__address: 0.0.0.0:7474
      NEO4J_server_bolt_listen__address: 0.0.0.0:7687
    volumes: [ ff_neo4j:/data ]
    ports: [ "127.0.0.1:7474:7474", "127.0.0.1:7687:7687" ]
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:7474 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 60

  minio:
    image: quay.io/minio/minio:RELEASE.2024-10-02T17-50-41Z
    container_name: ffactory_minio
    command: ["server","/data","--console-address",":9001"]
    env_file: [ ../.env ]
    volumes: [ ff_minio:/data ]
    ports: [ "127.0.0.1:9000:9000", "127.0.0.1:9001:9001" ]
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:9000/minio/health/ready"]
      interval: 10s
      timeout: 5s
      retries: 60
YML

# 4) تشغيل
log "compose up core"
docker compose -f "$STACK/docker-compose.core.yml" up -d

# 5) انتظار جاهزية الخدمات
wait_cmd(){ local name=$1 cmd=$2; for i in {1..90}; do eval "$cmd" && return 0; sleep 2; done; return 1; }

log "wait: postgres"
wait_cmd pg 'docker exec ffactory_db pg_isready -U "${POSTGRES_USER:-ffadmin}" >/dev/null' || { docker logs ffactory_db --tail=200; exit 3; }
log "wait: redis"
wait_cmd redis 'docker exec ffactory_redis redis-cli -a "${REDIS_PASSWORD:-ffredis}" PING | grep -q PONG' || { docker logs ffactory_redis --tail=200; exit 3; }
log "wait: neo4j"
wait_cmd neo4j 'curl -fsS http://127.0.0.1:7474 >/dev/null' || { docker logs ffactory_neo4j --tail=200; exit 3; }
log "wait: minio"
wait_cmd minio 'curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null' || { docker logs ffactory_minio --tail=200; exit 3; }

# 6) لقطة احتياطية للـapps والـscripts
TS=$(date +%F-%H%M%S)
install -d -m 755 "$BACK"
tar -C /opt -czf "$BACK/apps-full-$TS.tgz" ffactory/apps || true
sha256sum "$BACK/apps-full-$TS.tgz" | tee "$BACK/apps-full-$TS.tgz.sha256" || true
tar -C /opt -czf "$BACK/scripts-$TS.tgz" ffactory/scripts || true
sha256sum "$BACK/scripts-$TS.tgz" | tee "$BACK/scripts-$TS.tgz.sha256" || true

# 7) ملخص
echo
echo "==== Ports ===="
ss -lnt | awk 'NR==1||/:(5433|6379|7474|7687|9000|9001)\b/'
echo
echo "==== Containers ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_ || true
echo
echo "[DONE]"
