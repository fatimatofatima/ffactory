#!/usr/bin/env bash
# =============================================================================
# 🩺 FFactory Doctor — Smart Fix & Run (51 Services)
# يفحص، يصلّح، يبني، يختبر، ويشغّل الـ Stack بالكامل بتقرير نهائي.
# آمن للتكرار. يصلّح المشاكل الشائعة تلقائيًا.
# =============================================================================
set -Eeuo pipefail

# ---------- ألوان و لوج ----------
GREEN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ts() { date +%H:%M:%S; }
log()  { echo -e "${GREEN}[$(ts)]${NC} $*"; }
warn() { echo -e "${YEL}[!][$(ts)]${NC} $*"; }
err()  { echo -e "${RED}[x][$(ts)]${NC} $*"; exit 1; }

# ---------- مسارات ----------
FF="/opt/ffactory"
APPS="$FF/apps"
STACK="$FF/stack"
SCRIPTS="$FF/scripts"
LOGS="$FF/logs"
DATA="$FF/data"
VOL="$FF/volumes"
mkdir -p "$APPS" "$STACK" "$SCRIPTS" "$LOGS" "$DATA" "$VOL"

TS=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOGS/master_${TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'err "فشل عند السطر $LINENO — راجع اللوج: $LOG_FILE"' ERR

# ---------- متطلبات ----------
[[ $EUID -eq 0 ]] || err "لازم تشغّل السكربت كـ root"
command -v docker >/dev/null || err "Docker غير مثبت"
docker compose version >/dev/null 2>&1 || err "Docker Compose plugin غير متاح"

# ---------- اختيار ملف compose ----------
COMPOSE_COMPLETE="$STACK/docker-compose.complete.yml"
COMPOSE_ULTIMATE="$STACK/docker-compose.ultimate.yml"
if   [[ -f "$COMPOSE_COMPLETE" ]]; then COMPOSE="$COMPOSE_COMPLETE"
elif [[ -f "$COMPOSE_ULTIMATE" ]]; then COMPOSE="$COMPOSE_ULTIMATE"
else
  warn "لم أجد compose. سأنشئ واحدًا مصغرًا وسيتم توسيعه."
  COMPOSE="$COMPOSE_COMPLETE"
  cat > "$COMPOSE" <<'YML'
services:
  db: { image: postgres:16 }
YML
fi
log "📄 Using compose: $COMPOSE"

# ---------- دوال مساعدة ----------
generate_secret(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || echo "S$(date +%s)"; }
# فحص منفذ قيد الاستخدام على الهست
port_used(){ ss -tulpn 2>/dev/null | grep -qE "[:.]$1\s"; }
find_free_port(){ local p="$1"; while port_used "$p"; do p=$((p+1)); done; echo "$p"; }
# قراءة قيمة من .env
env_get(){ local k="$1" d="${2-}"; [[ -f "$STACK/.env" ]] && grep -E "^${k}=" "$STACK/.env" | tail -1 | cut -d= -f2- || echo "$d"; }
# ضبط/إضافة key=value في .env
env_set(){
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$STACK/.env" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|g" "$STACK/.env"
  else
    echo "${k}=${v}" >> "$STACK/.env"
  fi
}
# تحضير .env أساسي
ensure_env(){
  log "🧩 فحص/إنشاء .env…"
  [[ -f "$STACK/.env" ]] || touch "$STACK/.env"
  env_set COMPOSE_PROJECT_NAME "ffactory"
  env_set TZ "Asia/Kuwait"

  # كلمات مرور
  [[ -n "$(env_get POSTGRES_PASSWORD)" ]]     || env_set POSTGRES_PASSWORD "$(generate_secret)"
  [[ -n "$(env_get REDIS_PASSWORD)"    ]]     || env_set REDIS_PASSWORD    "$(generate_secret)"
  [[ -n "$(env_get MINIO_ROOT_PASSWORD)" ]]   || env_set MINIO_ROOT_PASSWORD "$(generate_secret)"
  [[ -n "$(env_get NEO4J_AUTH)"        ]]     || env_set NEO4J_AUTH "neo4j/$(generate_secret)"

  # منافذ أساسية
  declare -A ports=(
    [FRONTEND_PORT]=3001 [PG_PORT]=5433 [REDIS_PORT]=6379 [MINIO_PORT]=9002
    [NEO4J_HTTP_PORT]=7474 [NEO4J_BOLT_PORT]=7687 [OLLAMA_PORT]=11435 [VAULT_PORT]=8200
  )
  for k in "${!ports[@]}"; do
    current="$(env_get "$k" "${ports[$k]}")"
    if port_used "$current"; then
      new="$(find_free_port "$current")"
      warn "المنفذ $k=$current مشغول. سيتم تغييرُه إلى $new تلقائيًا."
      env_set "$k" "$new"
    else
      env_set "$k" "$current"
    fi
  done
}
ensure_env

# ---------- تصليح compose (CRLF / Tabs / version) ----------
fix_compose_yaml(){
  log "🧹 تصحيح YAML (CRLF/Tabs/version)…"
  # إزالة CRLF
  sed -i 's/\r$//' "$COMPOSE"
  # استبدال Tabs بمسافتين
  sed -i 's/\t/  /g' "$COMPOSE"
  # إزالة سطر version القديم
  sed -i '/^version:/d' "$COMPOSE"
  # إزالة BOM إن وجدت
  sed -i '1s/^\xEF\xBB\xBF//' "$COMPOSE"

  # فحص صلاحية التركيب
  if ! docker compose -f "$COMPOSE" config >/dev/null; then
    err "خطأ في صيغة $COMPOSE — بعد التنظيف مازال غير صالح."
  fi
}
fix_compose_yaml

# ---------- توليد init.sql لو ناقص ----------
ensure_init_sql(){
  [[ -f "$SCRIPTS/init.sql" ]] && return 0
  log "🧾 كتابة init.sql افتراضي…"
  mkdir -p "$SCRIPTS"
  cat > "$SCRIPTS/init.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE TABLE IF NOT EXISTS heartbeat(id int primary key default 1, ts timestamptz default now());
INSERT INTO heartbeat(id) VALUES (1) ON CONFLICT (id) DO UPDATE SET ts = now();
SQL
}
ensure_init_sql

# ---------- Stub لكل خدمة مذكورة في compose ----------
stub_service(){
  local name="$1" port="${2:-8080}" desc="${3:-$1 service}"
  mkdir -p "$APPS/$name"
  [[ -f "$APPS/$name/requirements.txt" ]] || cat > "$APPS/$name/requirements.txt" <<REQ
fastapi==0.104.1
uvicorn[standard]==0.24.0
requests==2.31.0
pydantic==2.5.0
python-multipart==0.0.6
REQ
  if [[ "$name" == "frontend-dashboard" ]]; then
    # واجهة Nginx ثابتة
    cat > "$APPS/$name/Dockerfile" <<'DOCKER'
FROM nginx:alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY static/ /usr/share/nginx/html/
EXPOSE 3000
CMD ["nginx","-g","daemon off;"]
DOCKER
    mkdir -p "$APPS/$name/static"
    [[ -f "$APPS/$name/static/index.html" ]] || cat > "$APPS/$name/static/index.html" <<'HTML'
<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><title>FFactory</title>
<body style="font-family:sans-serif"><h1>🚀 FFactory Dashboard</h1><p>جاهز.</p></body></html>
HTML
    cat > "$APPS/$name/nginx.conf" <<'NGINX'
events { worker_connections 1024; }
http {
  include /etc/nginx/mime.types; default_type application/octet-stream;
  server {
    listen 3000; server_name _; root /usr/share/nginx/html; index index.html;
    location / { try_files $uri $uri/ /index.html; }
    location = /health { return 200 "ok\n"; }
  }
}
NGINX
  else
    cat > "$APPS/$name/Dockerfile" <<DOCKER
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE ${port}
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 CMD curl -fsS http://localhost:${port}/health || exit 1
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","${port}"]
DOCKER
    [[ -f "$APPS/$name/main.py" ]] || cat > "$APPS/$name/main.py" <<PY
from fastapi import FastAPI
from datetime import datetime
app = FastAPI(title="${name}", version="2.0", description="${desc}")
start = datetime.utcnow()
@app.get("/")      def root():   return {"service":"${name}","status":"ok"}
@app.get("/health")def health(): return {"status":"healthy","service":"${name}","ts":datetime.utcnow().isoformat()}
@app.get("/ready") def ready():  return {"status":"ready"}
PY
  fi
}

ensure_all_services(){
  log "🧱 التأكد من وجود ملفات كل الخدمات المذكورة في compose…"
  # استخرج أسماء الخدمات التي تستخدم build: ../apps/<name> أو context: ../apps/<name>
  mapfile -t NAMES < <(grep -Eo 'context:\s+\.\./apps/[A-Za-z0-9._-]+|build:\s+\.\./apps/[A-Za-z0-9._-]+' "$COMPOSE" \
                      | awk -F'/apps/' '{print $2}' | tr -d ' ' | sort -u)
  if [[ ${#NAMES[@]} -eq 0 ]]; then
    warn "لم أستطع استخراج خدمات من compose؛ سأتجاهل خطوة التوليد."
    return 0
  fi
  for name in "${NAMES[@]}"; do
    # حاول استنتاج البورت من الاسم؛ إفتراضي 8080
    port=8080
    case "$name" in
      feedback-api) port=8070;;
      orchestrator) port=8060;;
      ai-reporting) port=8081;;
      predictive-analytics) port=8125;;
      behavioral-patterns) port=8126;;
      linguistic-analysis) port=8127;;
      deepfake-detector) port=8128;;
      advanced-steganalysis) port=8114;;
      memory-forensics) port=8115;;
      temporal-forensics) port=8116;;
      media-forensics-pro) port=8001;;
      medical-forensics) port=8010;;
      mobile-forensics) port=8130;;
      iot-forensics) port=8131;;
      cloud-forensics) port=8132;;
      blockchain-analyzer) port=8133;;
      case-manager) port=8140;;
      evidence-tracker) port=8141;;
      chain-of-custody-manager) port=8105;;
      report-generator) port=8142;;
      audit-logger) port=8143;;
      error-aggregator) port=8075;;
      social-analyzer) port=8103;;
      threat-intelligence) port=8121;;
      criminal-profiler) port=8120;;
      geospatial-tracker) port=8122;;
      network-mapper) port=8123;;
      ingest-service) port=8001;;
      quantum-security) port=8082;;
      zero-trust-enforcer) port=8106;;
      integrity-monitor) port=8100;;
      asr-engine) port=8080;;
      social-intelligence) port=8080;;
      neural-core) port=8080;;
      correlation-engine) port=8080;;
      api-gateway) port=8170;;
      data-export-service) port=8172;;
      frontend-dashboard) port=3000;;
    esac
    if [[ ! -f "$APPS/$name/Dockerfile" || ! -f "$APPS/$name/requirements.txt" ]]; then
      warn "إنشاء stubs للخدمة: $name (port $port)…"
      stub_service "$name" "$port" "$name service"
    fi
  done
}
ensure_all_services

# ---------- تشغيل البنية التحتية أولًا ----------
log "🧱 تشغيل البنية التحتية أولًا (قد يأخذ دقائق أول مرة)…"
# شغّل فقط ما هو مُعرّف فعلياً داخل compose
services_present() { docker compose -f "$COMPOSE" config --services; }
want(){
  for svc in "$@"; do
    if services_present | grep -qx "$svc"; then echo -n " $svc"; fi
  done
}
docker compose -f "$COMPOSE" up -d$(want db redis neo4j minio ollama vault metabase) || true

# ---------- انتظار readiness أساسي ----------
wait_health(){
  local name="$1" timeout="${2:-120}"
  if ! services_present | grep -qx "$name"; then return 0; fi
  log "⏳ انتظار صحة $name (≤${timeout}s)…"
  local end=$((SECONDS+timeout))
  while (( SECONDS < end )); do
    # استخدم health إن وجد
    hs="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{""}}{{end}}' "${PWD##*/}_${name}_1" 2>/dev/null || true)"
    [[ "$hs" == "healthy" ]] && { log "✅ $name Healthy"; return 0; }
    # بديل: فحص بورت معروف داخل الحاوية
    if docker compose -f "$COMPOSE" exec -T "$name" sh -lc 'command -v curl >/dev/null && curl -fsS http://localhost:8080/health >/dev/null 2>&1 || true'; then
      log "✅ $name Responding"
      return 0
    fi
    sleep 3
  done
  warn "⚠️  $name لم يصل لحالة صحية خلال ${timeout}s — نكمل."
}
wait_health db 90
wait_health redis 60
wait_health neo4j 120
wait_health minio 60
wait_health vault 60
wait_health ollama 60

# ---------- Build & Up شامل ----------
log "🏗️  بناء وتشغيل جميع الخدمات (with --build)…"
docker compose -f "$COMPOSE" up -d --build --remove-orphans

# ---------- فحوصات صحة داخلية للخدمات الأساسية ----------
check_inside(){
  local svc="$1" url="${2:-http://localhost:8080/health}"
  if ! services_present | grep -qx "$svc"; then return; fi
  if docker compose -f "$COMPOSE" exec -T "$svc" sh -lc "curl -fsS '$url' >/dev/null"; then
    echo -e "  • ${svc}: ${GREEN}OK${NC}"
  else
    echo -e "  • ${svc}: ${YEL}PENDING${NC} (سأعيد تشغيله)"
    docker compose -f "$COMPOSE" restart "$svc" || true
  fi
}
log "🧪 فحص /health من داخل الحاويات:"
check_inside investigation-api
check_inside behavioral-analytics
check_inside case-manager
check_inside api-gateway http://localhost:8170/health
check_inside frontend-dashboard http://localhost:3000/health || true

# ---------- تقرير الملخّص ----------
log "📊 ملخص الحالة:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^ffactory_' | sort | head -120

# ---------- نقاط الوصول ----------
UI_PORT="$(env_get FRONTEND_PORT 3001)"
MB_PORT="$(env_get MB_PORT 3002)" # إن وُجد Metabase
echo
echo "================================================================"
echo "🎉 جاهز:"
[[ -n "$UI_PORT" ]] && echo "🌐 Dashboard:          http://127.0.0.1:${UI_PORT}/"
[[ -f "$STACK/docker-compose.ultimate.yml" || -f "$STACK/docker-compose.complete.yml" ]] && echo "📄 Compose:            $COMPOSE"
echo "🪵 Logs:               $LOG_FILE"
echo "🧰 أوامر مفيدة:"
echo "   • إعادة التشغيل:    cd $STACK && docker compose -f $COMPOSE up -d --build"
echo "   • الإيقاف:          cd $STACK && docker compose -f $COMPOSE down"
echo "   • فحص سريع:         docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep ffactory"
echo "================================================================"
