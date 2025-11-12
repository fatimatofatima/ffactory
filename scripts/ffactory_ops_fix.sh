#!/usr/bin/env bash
set -Eeuo pipefail

# ========= Vars =========
BASE=/opt/ffactory
STACK=$BASE/stack
APPS=$BASE/apps
OPS_YAML=$STACK/docker-compose.ops.yml
NET=ffactory_default
PASS=0; FAIL=0; WARN=0
ok(){ echo "✅ $*"; ((PASS++))||true; }
wi(){ echo "⚠️  $*"; ((WARN++))||true; }
er(){ echo "❌ $*"; ((FAIL++))||true; }

ts(){ date +%F' '%T; }
log(){ printf '[%s] %s\n' "$(ts)" "$*"; }

need(){ command -v "$1" >/dev/null 2>&1 || { er "Missing binary: $1"; exit 10; }; }

mkdir -p "$STACK" "$APPS/ingest-gateway" "$APPS/graph-writer"

# ========= Preflight =========
need docker
if docker compose version >/dev/null 2>&1; then ok "docker compose v2 available"; else er "docker compose not found"; exit 11; fi

# ========= Sysctl for OpenSearch =========
log "Tune sysctl for OpenSearch"
sudo sysctl -w vm.max_map_count=524288 >/dev/null || wi "vm.max_map_count set failed (non-fatal)"
sudo sysctl -w fs.file-max=131072   >/dev/null || wi "fs.file-max set failed (non-fatal)"
sudo tee /etc/sysctl.d/99-ffactory.conf >/dev/null <<EOF || true
vm.max_map_count=524288
fs.file-max=131072
EOF
sudo sysctl --system >/dev/null || true
ok "sysctl tuned"

# ========= Write docker-compose.ops.yml (clean) =========
log "Write $OPS_YAML"
cat > "$OPS_YAML" <<'YML'
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
  neo4j_data:

services:
  opensearch-node1:
    image: opensearchproject/opensearch:2.11.0
    environment:
      - cluster.name=ffactory-opensearch
      - node.name=opensearch-node1
      - discovery.seed_hosts=opensearch-node1,opensearch-node2
      - cluster.initial_master_nodes=opensearch-node1,opensearch-node2
      - bootstrap.memory_lock=true
      - "OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m"
      - plugins.security.disabled=true
    ulimits:
      memlock: { soft: -1, hard: -1 }
    volumes:
      - opensearch_data1:/usr/share/opensearch/data
    ports:
      - "127.0.0.1:9200:9200"
    networks: [ffactory_default]
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:9200"]
      interval: 20s
      timeout: 10s
      retries: 10

  opensearch-node2:
    image: opensearchproject/opensearch:2.11.0
    environment:
      - cluster.name=ffactory-opensearch
      - node.name=opensearch-node2
      - discovery.seed_hosts=opensearch-node1,opensearch-node2
      - cluster.initial_master_nodes=opensearch-node1,opensearch-node2
      - bootstrap.memory_lock=true
      - "OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m"
      - plugins.security.disabled=true
    ulimits:
      memlock: { soft: -1, hard: -1 }
    volumes:
      - opensearch_data2:/usr/share/opensearch/data
    networks: [ffactory_default]
    depends_on: { opensearch-node1: { condition: service_healthy } }

  opensearch-dashboards:
    image: opensearchproject/opensearch-dashboards:2.11.0
    ports: ["127.0.0.1:5601:5601"]
    environment:
      - 'OPENSEARCH_HOSTS=["http://opensearch-node1:9200"]'
    networks: [ffactory_default]
    depends_on: { opensearch-node1: { condition: service_healthy } }
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:5601"]
      interval: 30s
      timeout: 10s
      retries: 10

  zookeeper:
    image: confluentinc/cp-zookeeper:7.4.0
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    networks: [ffactory_default]

  kafka:
    image: confluentinc/cp-kafka:7.4.0
    depends_on: [zookeeper]
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
    ports: ["127.0.0.1:9092:9092"]
    volumes: [kafka_data:/var/lib/kafka/data]
    networks: [ffactory_default]
    healthcheck:
      test: ["CMD","bash","-lc","kafka-topics --list --bootstrap-server localhost:9092 >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10

  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: admin
      MINIO_ROOT_PASSWORD: ChangeMe_12345
    volumes: [minio_data:/data]
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
    networks: [ffactory_default]
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:9000/minio/health/live"]
      interval: 20s
      timeout: 10s
      retries: 10

  neo4j:
    image: neo4j:5
    environment:
      NEO4J_AUTH: neo4j/test123
      NEO4J_dbms_security_procedures_unrestricted: "apoc.*,gds.*"
      NEO4JLABS_PLUGINS: '["apoc","graph-data-science"]'
    volumes:
      - neo4j_data:/data
    ports:
      - "127.0.0.1:7474:7474"
      - "127.0.0.1:7687:7687"
    networks: [ffactory_default]
    healthcheck:
      test: ["CMD","bash","-lc","curl -fsS http://localhost:7474 >/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 20

  ingest-gateway:
    build: ../apps/ingest-gateway
    environment:
      KAFKA_BROKER: kafka:9092
      OPENSEARCH_HOST: opensearch-node1:9200
      POSTGRES_URL: postgresql://forensic_user:forensic_pass@db:5432/forensic_db
      NEO4J_URL: bolt://neo4j:7687
      NEO4J_USER: neo4j
      NEO4J_PASSWORD: test123
      MINIO_URL: http://minio:9000
      MINIO_ACCESS_KEY: admin
      MINIO_SECRET_KEY: ChangeMe_12345
    ports: ["127.0.0.1:8088:8088"]
    networks: [ffactory_default]
    depends_on:
      opensearch-node1: { condition: service_healthy }
      kafka:            { condition: service_healthy }
      neo4j:            { condition: service_healthy }
      minio:            { condition: service_healthy }

  graph-writer:
    build: ../apps/graph-writer
    environment:
      KAFKA_BROKER: kafka:9092
      NEO4J_URL: bolt://neo4j:7687
      NEO4J_USER: neo4j
      NEO4J_PASSWORD: test123
    networks: [ffactory_default]
    depends_on:
      kafka: { condition: service_healthy }
      neo4j: { condition: service_healthy }
YML
ok "OPS compose written"

# ========= Ensure app sources exist (ingest & graph) =========
if [ ! -f "$APPS/ingest-gateway/requirements.txt" ]; then
  cat > "$APPS/ingest-gateway/requirements.txt" <<EOF
fastapi==0.104.1
uvicorn[standard]==0.24.0
kafka-python==2.0.2
opensearch-py==2.4.0
psycopg2-binary==2.9.9
neo4j==5.14.0
minio==7.1.15
python-multipart==0.0.6
EOF
  cat > "$APPS/ingest-gateway/Dockerfile" <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8088
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8088"]
EOF
  cat > "$APPS/ingest-gateway/main.py" <<'EOF'
from fastapi import FastAPI
from kafka import KafkaProducer
from opensearchpy import OpenSearch
from minio import Minio
import json, uuid
from datetime import datetime

app = FastAPI(title="FFactory Ingest Gateway")
producer = KafkaProducer(bootstrap_servers=['kafka:9092'],
                         value_serializer=lambda v: json.dumps(v).encode('utf-8'))
os = OpenSearch(['http://opensearch-node1:9200'])
mc = Minio("minio:9000", access_key="admin", secret_key="ChangeMe_12345", secure=False)

@app.get("/health")
def health(): return {"status":"ok"}

@app.post("/ingest/event")
def ingest_event(event: dict):
    event_id = str(uuid.uuid4()); event["@timestamp"]=datetime.utcnow().isoformat(); event["event_id"]=event_id
    producer.send('forensic-events', event)
    os.index(index="forensic-events", body=event, id=event_id)
    data=json.dumps(event).encode("utf-8")
    mc.put_object("raw-events", f"{event_id}.json", data, len(data))
    return {"ok":True, "event_id":event_id}
EOF
fi
ok "ingest-gateway sources ready"

if [ ! -f "$APPS/graph-writer/requirements.txt" ]; then
  cat > "$APPS/graph-writer/requirements.txt" <<EOF
kafka-python==2.0.2
neo4j==5.14.0
EOF
  cat > "$APPS/graph-writer/Dockerfile" <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python","main.py"]
EOF
  cat > "$APPS/graph-writer/main.py" <<'EOF'
from kafka import KafkaConsumer
from neo4j import GraphDatabase
import json, logging
logging.basicConfig(level=logging.INFO)
driver = GraphDatabase.driver("bolt://neo4j:7687", auth=("neo4j","test123"))
consumer = KafkaConsumer('forensic-events', bootstrap_servers=['kafka:9092'],
                         value_deserializer=lambda m: json.loads(m.decode('utf-8')))
def handle(e):
    with driver.session() as s:
        if e.get('event_type')=='login_attempt':
            s.run("""MERGE (u:User {id:$user_id})""", user_id=e.get('user_id'))
        # (تبسيط) يمكن توسعة المنطق
for msg in consumer:
    try: handle(msg.value)
    except Exception as ex: logging.exception(ex)
EOF
fi
ok "graph-writer sources ready"

# ========= Build & Up =========
log "Build ops apps"
docker compose -p ffactory -f "$OPS_YAML" build || wi "build warnings (non-fatal)"
log "Up ops"
docker compose -p ffactory -f "$OPS_YAML" up -d || er "OPS up failed"

# ========= Waiters =========
wait_http(){ local url="$1"; local name="$2"; local t="${3:-120}"; 
  for i in $(seq 1 "$t"); do
    if curl -fsS "$url" >/dev/null 2>&1; then ok "$name ready ($url)"; return 0; fi
    sleep 1
  done
  wi "$name not ready after ${t}s ($url)"; return 1
}

wait_http "http://127.0.0.1:9200" "OpenSearch" 150 || true
wait_http "http://127.0.0.1:5601" "Dashboards"  120 || true
wait_http "http://127.0.0.1:9001" "MinIO Console" 120 || true
wait_http "http://127.0.0.1:7474" "Neo4j Browser" 180 || true

# ========= Post-init (Kafka topic / OS index / MinIO bucket) =========
# Kafka container name by labels
KAFKA_CONT=$(docker ps --filter "label=com.docker.compose.project=ffactory" --filter "label=com.docker.compose.service=kafka" --format "{{.Names}}" | head -n1 || true)
if [ -n "$KAFKA_CONT" ]; then
  if docker exec -i "$KAFKA_CONT" kafka-topics --bootstrap-server kafka:9092 --create --if-not-exists --topic forensic-events --replication-factor 1 --partitions 3 >/dev/null 2>&1; then
    ok "Kafka topic forensic-events"
  else wi "Kafka topic init skipped"; fi
else wi "Kafka container not found"; fi

# OpenSearch index
if curl -fsS -XPUT "http://127.0.0.1:9200/forensic-events" -H 'Content-Type: application/json' \
  -d '{"settings":{"number_of_shards":1},"mappings":{"properties":{"@timestamp":{"type":"date"}}}}' >/dev/null 2>&1; then
  ok "OpenSearch index forensic-events"
else wi "OpenSearch index init skipped"; fi

# MinIO bucket
if docker run --rm --network "$NET" -e MC_HOST_minio=http://admin:ChangeMe_12345@minio:9000 minio/mc mb minio/raw-events >/dev/null 2>&1; then
  ok "MinIO bucket raw-events"
else wi "MinIO bucket init skipped"; fi

# ========= Summary =========
echo
echo "=== Ops Status ==="
docker compose -p ffactory -f "$OPS_YAML" ps

echo
echo "=== Final Summary ==="
echo "PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
