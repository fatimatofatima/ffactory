#!/usr/bin/env bash
# FFactory Doctor – one-shot setup, repair, and report
# Usage:
#   bash /opt/ffactory/scripts/ffactory_doctor.sh
#   FF_FORCE=1 FF_ENABLE_MISP=1 bash /opt/ffactory/scripts/ffactory_doctor.sh

set -o pipefail

# ===================== Vars =====================
TZ_DEFAULT="Asia/Kuwait"
BASE="/opt/ffactory"
STACK="$BASE/stack"
APPS="$BASE/apps"
BOTS="$APPS/telegram-bots"
INIT="$STACK/init"
REPORT_DIR="$BASE/reports"
REPORT_FILE="$REPORT_DIR/ffactory_report_$(date +%F_%H%M%S).txt"
DB_ENV="$STACK/db.env"
BOTS_ENV="$STACK/.env.bots"
CORE_YAML="$STACK/docker-compose.core.yml"
OPS_YAML="$STACK/docker-compose.ops.yml"
FF_FORCE="${FF_FORCE:-0}"
FF_ENABLE_MISP="${FF_ENABLE_MISP:-0}"

mkdir -p "$STACK" "$APPS" "$BOTS" "$INIT" "$REPORT_DIR"

PASS=0; FAIL=0; WARN=0
log(){ printf "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$REPORT_FILE"; }
ok(){ PASS=$((PASS+1)); log "✅ $*"; }
ko(){ FAIL=$((FAIL+1)); log "❌ $*"; }
wi(){ WARN=$((WARN+1)); log "⚠️  $*"; }

run(){ # run "DESC" cmd...
  local desc="$1"; shift
  if eval "$@" >/dev/null 2>&1; then ok "$desc"; return 0
  else ko "$desc"; log "    ↳ cmd: $*"; return 1; fi
}

need(){ # need "tool" "pkg hint"
  if ! command -v "$1" >/dev/null 2>&1; then
    ko "Missing dependency: $1 ($2)"; return 1
  else ok "Found: $1"; fi
}

# ===================== Preconditions =====================
log "=== FFactory Doctor started ==="
need docker "install docker-ce" || true
if docker compose version >/dev/null 2>&1; then ok "docker compose v2 available"
elif docker-compose version >/dev/null 2>&1; then
  wi "Using legacy docker-compose; adjusting commands"
  alias docker='docker'  # no change
  alias dcompose='docker-compose'
else
  ko "No docker compose found"; fi

# unify compose command
if docker compose version >/dev/null 2>&1; then
  dcompose(){ docker compose "$@"; }
else
  dcompose(){ docker-compose "$@"; }
fi

# ===================== Files: env & init =====================
if [ ! -s "$DB_ENV" ] || [ "$FF_FORCE" = "1" ]; then
  cat >"$DB_ENV" <<EOF
POSTGRES_USER=forensic_user
POSTGRES_PASSWORD=forensic_pass
POSTGRES_DB=forensic_db
PGUSER=forensic_user
PGPASSWORD=forensic_pass
PGDB=forensic_db
TZ=${TZ_DEFAULT}
EOF
  ok "Wrote $DB_ENV"
else ok "Keep existing $DB_ENV"; fi
chmod 600 "$DB_ENV" || true

if [ ! -s "$BOTS_ENV" ]; then
  cat >"$BOTS_ENV" <<EOF
NEXTWIN_TOKEN=
MYSERV_TOKEN=
ALLOWED_USERS=
DB_URL=postgresql://forensic_user:forensic_pass@db:5432/forensic_db
TZ=${TZ_DEFAULT}
EOF
  wi "Created $BOTS_ENV (fill your bot tokens!)"
else ok "Keep existing $BOTS_ENV"; fi
chmod 600 "$BOTS_ENV" || true

# init SQL (idempotent)
cat >"$INIT/init_security.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS login_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  login_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip_address INET,
  success BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_login_time ON login_attempts(login_time);
CREATE INDEX IF NOT EXISTS idx_login_user ON login_attempts(user_id);

CREATE TABLE IF NOT EXISTS network_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  event_type TEXT NOT NULL,
  source_ip INET,
  destination_ip INET,
  destination_port INT,
  protocol TEXT,
  bytes_sent BIGINT DEFAULT 0,
  bytes_received BIGINT DEFAULT 0,
  meta JSONB
);
CREATE INDEX IF NOT EXISTS idx_net_time ON network_events(event_time);
CREATE INDEX IF NOT EXISTS idx_net_src  ON network_events(source_ip);
CREATE INDEX IF NOT EXISTS idx_net_dst  ON network_events(destination_ip);
SQL
ok "Prepared $INIT/init_security.sql"

# ===================== Core compose =====================
if [ ! -s "$CORE_YAML" ] || [ "$FF_FORCE" = "1" ]; then
cat >"$CORE_YAML" <<'YAML'
version: "3.8"

networks:
  ffactory_default:
    name: ffactory_default
    driver: bridge

volumes:
  ffactory_db_data:
  ffactory_redis_data:

services:
  db:
    image: postgres:15
    env_file: [./db.env]
    volumes:
      - ffactory_db_data:/var/lib/postgresql/data
      - ./init/init_security.sql:/docker-entrypoint-initdb.d/init_security.sql:ro
    networks: [ffactory_default]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    networks: [ffactory_default]
    healthcheck:
      test: ["CMD","redis-cli","ping"]
      interval: 10s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  metabase:
    image: metabase/metabase:latest
    ports: ["127.0.0.1:3000:3000"]
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: ${POSTGRES_DB}
      MB_DB_PORT: 5432
      MB_DB_USER: ${POSTGRES_USER}
      MB_DB_PASS: ${POSTGRES_PASSWORD}
      MB_DB_HOST: db
      TZ: ${TZ}
    networks: [ffactory_default]
    depends_on:
      db: { condition: service_healthy }
    restart: unless-stopped
YAML
  ok "Wrote $CORE_YAML"
else ok "Keep existing $CORE_YAML"; fi

# ===================== Ops compose =====================
if [ ! -s "$OPS_YAML" ] || [ "$FF_FORCE" = "1" ]; then
cat >"$OPS_YAML" <<'YAML'
version: "3.8"
networks:
  ffactory_default:
    external: true
    name: ffactory_default

volumes:
  opensearch_data1:
  opensearch_data2:
  kafka_data:
  minio_data:

services:
  opensearch-node1:
    image: opensearchproject/opensearch:2.11.0
    environment:
      - cluster.name=ffactory-opensearch
      - node.name=opensearch-node1
      - discovery.seed_hosts=opensearch-node1,opensearch-node2
      - cluster.initial_master_nodes=opensearch-node1,opensearch-node2
      - bootstrap.memory_lock=true
      - OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m
      - plugins.security.disabled=true
    ulimits: { memlock: { soft: -1, hard: -1 } }
    volumes: [opensearch_data1:/usr/share/opensearch/data]
    ports: ["127.0.0.1:9200:9200"]
    networks: [ffactory_default]
    healthcheck:
      test: ["CMD","curl","-f","http://localhost:9200"]
      interval: 30s
      timeout: 10s
      retries: 5
    restart: unless-stopped

  opensearch-node2:
    image: opensearchproject/opensearch:2.11.0
    environment:
      - cluster.name=ffactory-opensearch
      - node.name=opensearch-node2
      - discovery.seed_hosts=opensearch-node1,opensearch-node2
      - cluster.initial_master_nodes=opensearch-node1,opensearch-node2
      - bootstrap.memory_lock=true
      - OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m
      - plugins.security.disabled=true
    ulimits: { memlock: { soft: -1, hard: -1 } }
    volumes: [opensearch_data2:/usr/share/opensearch/data]
    networks: [ffactory_default]
    restart: unless-stopped

  opensearch-dashboards:
    image: opensearchproject/opensearch-dashboards:2.11.0
    ports: ["127.0.0.1:5601:5601"]
    environment: ['OPENSEARCH_HOSTS=["http://opensearch-node1:9200"]']
    networks: [ffactory_default]
    depends_on: [opensearch-node1]
    restart: unless-stopped

  zookeeper:
    image: confluentinc/cp-zookeeper:7.4.0
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    networks: [ffactory_default]
    restart: unless-stopped

  kafka:
    image: confluentinc/cp-kafka:7.4.0
    depends_on: [zookeeper]
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
    ports: ["127.0.0.1:9092:9092"]
    volumes: [kafka_data:/var/lib/kafka/data]
    networks: [ffactory_default]
    healthcheck:
      test: ["CMD","kafka-topics","--list","--bootstrap-server","localhost:9092"]
      interval: 30s
      timeout: 10s
      retries: 5
    restart: unless-stopped

  neo4j:
    image: neo4j:5-community
    environment: [NEO4J_AUTH=neo4j/test123]
    ports: ["127.0.0.1:7474:7474","127.0.0.1:7687:7687"]
    networks: [ffactory_default]
    restart: unless-stopped

  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=admin
      - MINIO_ROOT_PASSWORD=ChangeMe_12345
    ports: ["127.0.0.1:9000:9000","127.0.0.1:9001:9001"]
    volumes: [minio_data:/data]
    networks: [ffactory_default]
    restart: unless-stopped

  timesketch:
    image: timesketch/timesketch:latest
    environment:
      - SECRET_KEY=ffactory-timesketch-secret
      - POSTGRES_PASSWORD=forensic_pass
      - POSTGRES_USER=forensic_user
      - POSTGRES_HOST=ffactory-db-1
      - POSTGRES_PORT=5432
      - REDIS_HOST=ffactory-redis-1
      - REDIS_PORT=6379
    ports: ["127.0.0.1:5000:5000"]
    networks: [ffactory_default]
    depends_on: [opensearch-node1]
    restart: unless-stopped

  ingest-gateway:
    build: ../apps/ingest-gateway
    ports: ["127.0.0.1:8088:8088"]
    environment:
      - KAFKA_BROKER=kafka:9092
      - OPENSEARCH_HOST=opensearch-node1:9200
      - POSTGRES_URL=postgresql://forensic_user:forensic_pass@ffactory-db-1:5432/forensic_db
      - NEO4J_URL=bolt://neo4j:7687
      - NEO4J_USER=neo4j
      - NEO4J_PASSWORD=test123
      - MINIO_URL=http://minio:9000
      - MINIO_ACCESS_KEY=admin
      - MINIO_SECRET_KEY=ChangeMe_12345
    networks: [ffactory_default]
    depends_on: [kafka, opensearch-node1, neo4j, minio]
    restart: unless-stopped

  graph-writer:
    build: ../apps/graph-writer
    environment:
      - KAFKA_BROKER=kafka:9092
      - NEO4J_URL=bolt://neo4j:7687
      - NEO4J_USER=neo4j
      - NEO4J_PASSWORD=test123
    networks: [ffactory_default]
    depends_on: [kafka, neo4j]
    restart: unless-stopped
YAML
  ok "Wrote $OPS_YAML"
else ok "Keep existing $OPS_YAML"; fi

# Optionally append MISP
if [ "$FF_ENABLE_MISP" = "1" ] && ! grep -q 'misp:' "$OPS_YAML"; then
cat >>"$OPS_YAML" <<'YAML'

  misp-db:
    image: mysql:8.0
    environment:
      - MYSQL_ROOT_PASSWORD=ChangeMeMISPDB123!
      - MYSQL_DATABASE=misp
      - MYSQL_USER=misp
      - MYSQL_PASSWORD=ChangeMeMISP123!
    networks: [ffactory_default]
    restart: unless-stopped

  misp-redis:
    image: redis:7-alpine
    networks: [ffactory_default]
    restart: unless-stopped

  misp:
    image: misp/core:latest
    environment:
      - MYSQL_HOST=misp-db
      - MYSQL_USER=misp
      - MYSQL_PASSWORD=ChangeMeMISP123!
      - MYSQL_DATABASE=misp
      - MYSQL_PORT=3306
      - REDIS_HOST=misp-redis
      - REDIS_PORT=6379
      - MISP_ADMIN_EMAIL=admin@ffactory.local
      - MISP_ADMIN_PASSWORD=ChangeMeMISPAdmin123!
      - MISP_BASEURL=http://127.0.0.1:8082
    ports: ["127.0.0.1:8082:80"]
    networks: [ffactory_default]
    depends_on: [misp-db, misp-redis]
    restart: unless-stopped
YAML
  ok "Appended MISP services to $OPS_YAML"
fi

# ===================== Apps: ingest/graph =====================
mkdir -p "$APPS/ingest-gateway" "$APPS/graph-writer"

cat >"$APPS/ingest-gateway/requirements.txt" <<'REQ'
fastapi==0.104.1
uvicorn[standard]==0.24.0
kafka-python==2.0.2
opensearch-py==2.4.0
psycopg2-binary==2.9.9
neo4j==5.14.0
minio==7.1.15
python-multipart==0.0.6
REQ

cat >"$APPS/ingest-gateway/Dockerfile" <<'DOCK'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8088
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8088"]
DOCK

cat >"$APPS/ingest-gateway/main.py" <<'PY'
from fastapi import FastAPI
from kafka import KafkaProducer
from opensearchpy import OpenSearch
from minio import Minio
import json, uuid
from datetime import datetime

app = FastAPI(title="FFactory Ingest Gateway")

producer = KafkaProducer(bootstrap_servers=["kafka:9092"],
                         value_serializer=lambda v: json.dumps(v).encode("utf-8"))
os = OpenSearch(["http://opensearch-node1:9200"])
mc = Minio("minio:9000", access_key="admin", secret_key="ChangeMe_12345", secure=False)

@app.post("/ingest/event")
async def ingest(event: dict):
    event_id = str(uuid.uuid4())
    event["@timestamp"] = datetime.utcnow().isoformat()
    event["event_id"] = event_id
    producer.send("forensic-events", event)
    os.index(index="forensic-events", body=event, id=event_id)
    data = json.dumps(event).encode()
    mc.put_object("raw-events", f"{event_id}.json", data, len(data))
    return {"status":"ok","event_id":event_id}

@app.get("/health")
def health(): return {"status":"ok"}
PY

cat >"$APPS/graph-writer/requirements.txt" <<'REQ'
kafka-python==2.0.2
neo4j==5.14.0
REQ

cat >"$APPS/graph-writer/Dockerfile" <<'DOCK'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python","main.py"]
DOCK

cat >"$APPS/graph-writer/main.py" <<'PY'
from kafka import KafkaConsumer
from neo4j import GraphDatabase
import json, logging
logging.basicConfig(level=logging.INFO); log=logging.getLogger("graph-writer")

driver = GraphDatabase.driver("bolt://neo4j:7687", auth=("neo4j","test123"))
consumer = KafkaConsumer("forensic-events",
    bootstrap_servers=["kafka:9092"],
    value_deserializer=lambda m: json.loads(m.decode("utf-8")))

def constraints():
    q = [
      "CREATE CONSTRAINT user_unique IF NOT EXISTS FOR (u:User) REQUIRE u.id IS UNIQUE",
      "CREATE CONSTRAINT ip_unique IF NOT EXISTS FOR (i:IP) REQUIRE i.addr IS UNIQUE"
    ]
    with driver.session() as s:
        for c in q:
            try: s.run(c); log.info("OK %s", c)
            except Exception as e: log.warning("skip %s (%s)", c, e)

def handle(e):
    with driver.session() as s:
        if e.get("event_type")=="login_attempt":
            s.run("""MERGE (u:User {id:$uid})
                     MERGE (ip:IP {addr:$ip})
                     MERGE (u)-[:LOGGED_FROM {ts:$ts,ok:$ok,id:$id}]->(ip)
                  """, uid=e.get("user_id"), ip=e.get("src_ip"),
                     ts=e.get("@timestamp"), ok=e.get("success",False), id=e.get("event_id"))
        elif e.get("event_type")=="network_connection":
            s.run("""MERGE (a:IP {addr:$src}) MERGE (b:IP {addr:$dst})
                     MERGE (a)-[:CONNECTED_TO {ts:$ts,port:$port,proto:$proto,id:$id}]->(b)
                  """, src=e.get("src_ip"), dst=e.get("dst_ip"), ts=e.get("@timestamp"),
                     port=e.get("dst_port"), proto=e.get("protocol"), id=e.get("event_id"))

def main():
    log.info("graph-writer starting...")
    constraints()
    for m in consumer:
        try: handle(m.value); log.info("event %s", m.value.get("event_id"))
        except Exception as e: log.error("event error: %s", e)

if __name__=="__main__": main()
PY

ok "Prepared apps (ingest-gateway, graph-writer)"

# ===================== Bots code =====================
cat >"$BOTS/enhanced_bot.py" <<'PY'
import os, logging, psycopg2
from telegram.ext import Application, CommandHandler, ContextTypes
from telegram import Update
from datetime import datetime
logging.basicConfig(level=logging.INFO); log=logging.getLogger("ffactory-bot")

TOKEN=os.getenv("BOT_TOKEN","")
DB_URL=os.getenv("DB_URL","postgresql://forensic_user:forensic_pass@db:5432/forensic_db")
ALLOWED={x.strip() for x in os.getenv("ALLOWED_USERS","").split(",") if x.strip()}

def allowed(uid:int)->bool: return (not ALLOWED) or (str(uid) in ALLOWED)

async def start(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if not allowed(u.effective_user.id): return
    await u.message.reply_text("✅ Bot ready")

async def idcmd(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if not allowed(u.effective_user.id): return
    uu=u.effective_user
    await u.message.reply_text(f"🪪 {uu.id} @{uu.username or 'N/A'}")

async def dbping(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if not allowed(u.effective_user.id): return
    try:
        with psycopg2.connect(DB_URL) as cn:
            with cn.cursor() as cur: cur.execute("SELECT 1")
        await u.message.reply_text(f"🗄️ DB OK @ {datetime.utcnow().isoformat()}")
    except Exception as e:
        await u.message.reply_text(f"❌ DB ERROR: {e}")

def main():
    if not TOKEN: raise SystemExit("TOKEN_MISSING")
    app=Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("id", idcmd))
    app.add_handler(CommandHandler("dbping", dbping))
    app.run_polling(drop_pending_updates=True, allowed_updates=["message","edited_message"])

if __name__=="__main__": main()
PY
ok "Prepared bots code"

# ===================== Bring up CORE =====================
cd "$STACK"
run "CORE: docker network ffactory_default" 'docker network inspect ffactory_default >/dev/null 2>&1 || docker network create ffactory_default'
run "CORE: up" 'dcompose --env-file ./db.env -p ffactory -f ./docker-compose.core.yml up -d'
sleep 2
run "CORE: wait for DB" 'docker exec -e PGPASSWORD=forensic_pass -i ffactory-db-1 pg_isready -U forensic_user -d forensic_db'

# Double-apply schema idempotently
docker exec -e PGPASSWORD=forensic_pass -i ffactory-db-1 psql -U forensic_user -d forensic_db -f /docker-entrypoint-initdb.d/init_security.sql >/dev/null 2>&1 && ok "CORE: schema applied" || wi "CORE: schema apply skipped"

# ===================== Bring up OPS =====================
run "OPS: build apps" "dcompose -f $OPS_YAML build"
run "OPS: up" "dcompose -f $OPS_YAML up -d"

# ===================== Bots containers =====================
set -a; . "$BOTS_ENV"; set +a
if [ -n "${NEXTWIN_TOKEN:-}" ] && [ -n "${MYSERV_TOKEN:-}" ]; then
  docker rm -f smartnext-bot myservtiydatatesr-bot >/dev/null 2>&1 || true

  run "BOT smartnext create" "
    docker run -d --name smartnext-bot \
      --network ffactory_default \
      -e BOT_TOKEN=\"$NEXTWIN_TOKEN\" \
      -e ALLOWED_USERS=\"${ALLOWED_USERS:-}\" \
      -e DB_URL=\"${DB_URL:-postgresql://forensic_user:forensic_pass@db:5432/forensic_db}\" \
      -v \"$BOTS\":/app -w /app \
      --restart unless-stopped \
      python:3.11-slim sh -c 'pip install --no-cache-dir python-telegram-bot==20.7 psycopg2-binary==2.9.9 httpx==0.25.2 && python enhanced_bot.py'
  "

  run "BOT myserv create" "
    docker run -d --name myservtiydatatesr-bot \
      --network ffactory_default \
      -e BOT_TOKEN=\"$MYSERV_TOKEN\" \
      -e ALLOWED_USERS=\"${ALLOWED_USERS:-}\" \
      -e DB_URL=\"${DB_URL:-postgresql://forensic_user:forensic_pass@db:5432/forensic_db}\" \
      -v \"$BOTS\":/app -w /app \
      --restart unless-stopped \
      python:3.11-slim sh -c 'pip install --no-cache-dir python-telegram-bot==20.7 psycopg2-binary==2.9.9 httpx==0.25.2 && python enhanced_bot.py'
  "

  # systemd units
  for svc in smartnext-bot myservtiydatatesr-bot; do
    UNIT="/etc/systemd/system/${svc}.service"
    if [ ! -s "$UNIT" ] || [ "$FF_FORCE" = "1" ]; then
      sudo bash -c "cat > '$UNIT' <<UNIT
[Unit]
Description=${svc} (Docker)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
[Service]
Restart=always
RestartSec=5
ExecStart=/usr/bin/docker start -a ${svc}
ExecStop=/usr/bin/docker stop -t 30 ${svc}
[Install]
WantedBy=multi-user.target
UNIT"
      run "systemd add $svc" "systemctl daemon-reload && systemctl enable --now $svc"
    else
      ok "systemd keep $svc"
    fi
  done
else
  wi "Bots skipped – fill tokens in $BOTS_ENV then re-run."
fi

# ===================== One-time inits =====================
# Kafka topic
docker exec -it ffactory_kafka kafka-topics --bootstrap-server kafka:9092 --create --if-not-exists --topic forensic-events --replication-factor 1 --partitions 3 >/dev/null 2>&1 \
  && ok "Kafka: topic forensic-events" || wi "Kafka: topic init skipped"

# OpenSearch index
curl -fsS -XPUT http://127.0.0.1:9200/forensic-events -H 'Content-Type: application/json' \
  -d '{"settings":{"number_of_shards":1},"mappings":{"properties":{"@timestamp":{"type":"date"}}}}' >/dev/null 2>&1 \
  && ok "OpenSearch: index forensic-events" || wi "OpenSearch: index init skipped"

# MinIO bucket
docker run --rm --network ffactory_default \
  -e MC_HOST_minio=http://admin:ChangeMe_12345@minio:9000 minio/mc mb minio/raw-events >/dev/null 2>&1 \
  && ok "MinIO: bucket raw-events" || wi "MinIO: bucket init skipped"

# ===================== Health checks =====================
echo "" | tee -a "$REPORT_FILE"
log "=== Health Summary ==="

# core
docker ps --format 'table {{.Names}}\t{{.Status}}' | tee -a "$REPORT_FILE"

# DB ping
docker exec -e PGPASSWORD=forensic_pass -i ffactory-db-1 psql -U forensic_user -d forensic_db -c "SELECT 1;" >/dev/null 2>&1 \
  && ok "DB ping" || ko "DB ping"

# Redis ping
docker exec -i ffactory-redis-1 redis-cli ping >/dev/null 2>&1 \
  && ok "Redis ping" || ko "Redis ping"

# Metabase port
curl -fsS http://127.0.0.1:3000 >/dev/null 2>&1 && ok "Metabase UI" || wi "Metabase UI not responding yet"

# OpenSearch/Kibana
curl -fsS http://127.0.0.1:9200 >/dev/null 2>&1 && ok "OpenSearch API" || wi "OpenSearch API"
curl -fsS http://127.0.0.1:5601 >/dev/null 2>&1 && ok "OpenSearch Dashboards" || wi "Dashboards"

# Kafka topics
docker exec -i ffactory_kafka kafka-topics --list --bootstrap-server kafka:9092 >/dev/null 2>&1 \
  && ok "Kafka list topics" || wi "Kafka list topics"

# Neo4j
curl -fsS http://127.0.0.1:7474 >/dev/null 2>&1 && ok "Neo4j UI" || wi "Neo4j UI"

# MinIO
curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null 2>&1 && ok "MinIO ready" || wi "MinIO ready"

# Timesketch
curl -fsS http://127.0.0.1:5000 >/dev/null 2>&1 && ok "Timesketch UI" || wi "Timesketch UI"

# MISP (optional)
if [ "$FF_ENABLE_MISP" = "1" ]; then
  curl -fsS http://127.0.0.1:8082 >/dev/null 2>&1 && ok "MISP UI" || wi "MISP UI"
fi

# Bots token checks (host-side)
if [ -n "${NEXTWIN_TOKEN:-}" ]; then
  curl -fsS "https://api.telegram.org/bot$NEXTWIN_TOKEN/getMe" >/dev/null 2>&1 \
    && ok "Telegram getMe (NEXTWIN)" || ko "Telegram getMe (NEXTWIN)"
fi
if [ -n "${MYSERV_TOKEN:-}" ]; then
  curl -fsS "https://api.telegram.org/bot$MYSERV_TOKEN/getMe" >/dev/null 2>&1 \
    && ok "Telegram getMe (MYSERV)" || ko "Telegram getMe (MYSERV)"
fi

echo "" | tee -a "$REPORT_FILE"
log "=== Final Report ==="
log "PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
log "Report saved: $REPORT_FILE"
log "URLs:"
log "  • Metabase:           http://127.0.0.1:3000"
log "  • OpenSearch:         http://127.0.0.1:9200"
log "  • Dashboards:         http://127.0.0.1:5601"
log "  • Timesketch:         http://127.0.0.1:5000"
log "  • Neo4j Browser:      http://127.0.0.1:7474"
log "  • MinIO Console:      http://127.0.0.1:9001"
log "  • Ingest API (docs):  http://127.0.0.1:8088/docs"
[ "$FF_ENABLE_MISP" = "1" ] && log "  • MISP:               http://127.0.0.1:8082"

exit 0
