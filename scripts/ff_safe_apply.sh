#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
STACK=/opt/ffactory/stack

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }

install -d -m 755 "$STACK"

# 1) depends_on بالصحة + بيئة DB داخل الشبكة
DEP="$STACK/docker-compose.depends.yml"
cat >"$DEP" <<'YML'
services:
  api_gateway:
    depends_on:
      db:    { condition: service_healthy }
      neo4j: { condition: service_healthy }
  investigation_api:
    depends_on:
      db:    { condition: service_healthy }
      neo4j: { condition: service_healthy }
  correlation_engine:
    depends_on:
      db:    { condition: service_healthy }
      neo4j: { condition: service_healthy }
  frontend-dashboard:
    depends_on:
      api_gateway: { condition: service_started }
YML

DBENV="$STACK/docker-compose.db-env.yml"
cat >"$DBENV" <<'YML'
services:
  api_gateway:
    environment: { DB_HOST: db, DB_PORT: "5432" }
  investigation_api:
    environment: { DB_HOST: db, DB_PORT: "5432" }
  correlation_engine:
    environment: { DB_HOST: db, DB_PORT: "5432" }
  behavioral_analytics:
    environment: { DB_HOST: db, DB_PORT: "5432" }
YML

# 2) جهّز قائمة compose كـ مصفوفة صحيحة
declare -a ARGS=()
# كل ملفات docker-compose*.yml الموجودة
while IFS= read -r -d '' f; do ARGS+=(-f "$f"); done \
  < <(find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' ! -name 'docker-compose.depends.yml' ! -name 'docker-compose.db-env.yml' -print0 | sort -z)

# أضف overrides التي أنشأناها
ARGS+=(-f "$DEP" -f "$DBENV")

# 3) أعِد فقط الخدمات المتأثرة بالترتيب والاعتمادية
export COMPOSE_IGNORE_ORPHANS=1
log "up -d للخدمات الأساسية التابعة لـ db/neo4j"
docker compose -p "$PROJECT" "${ARGS[@]}" up -d \
  api_gateway investigation_api correlation_engine frontend-dashboard || true

# 4) فحص سريع
sleep 8
log "حالة مختصرة:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$PROJECT" || true

# Prometheus و Frontend
if curl -fsS 127.0.0.1:9090/-/ready >/dev/null; then echo "Prometheus: OK"; else echo "Prometheus: BAD"; fi

front_ok=0
for p in 3001 3000; do
  if curl -fsS "http://127.0.0.1:$p/health" >/dev/null; then echo "Frontend:$p OK"; front_ok=1; break; fi
done
((front_ok==1)) || echo "Frontend: BAD"

# ملخص ff-healthd إن وُجد
if curl -fsS 127.0.0.1:9191/summary >/dev/null 2>&1; then
  echo "--- ff-healthd summary ---"
  curl -sS 127.0.0.1:9191/summary || true
fi

log "done."
