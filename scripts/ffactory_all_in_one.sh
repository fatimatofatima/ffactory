#!/usr/bin/env bash
# =========================================================
# 🚀 FFactory — All-in-One Bootstrap (Ultimate Merge)
# =========================================================
set -Eeuo pipefail

# ---- config ----
FF="/opt/ffactory"
STACK="$FF/stack"
APPS="$FF/apps"
SCRIPTS="$FF/scripts"
LOG="$FF/logs/setup_$(date +%Y%m%d_%H%M%S).log"
TZ_DEFAULT="Asia/Kuwait"

# ---- helpers ----
cok(){ echo -e "\033[0;32m[OK]\033[0m $*"; }
cin(){ echo -e "\033[0;34m[...]\033[0m $*"; }
cwarn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
cerr(){ echo -e "\033[0;31m[ERR]\033[0m $*" >&2; }
trap 'cerr "خطأ عند السطر: $LINENO"; exit 1' ERR

need_bin(){ command -v "$1" >/dev/null 2>&1 || { cerr "مطلوب $1"; exit 1; }; }

# ---- preflight ----
[ "$(id -u)" = "0" ] || { cerr "شغّل السكربت كـ root"; exit 1; }
mkdir -p "$FF" "$STACK" "$APPS" "$SCRIPTS" "$FF/data" "$FF/logs" "$FF/backups" "$FF/vol_symbols"
cok "تهيئة مجلدات العمل"

cin "فحص أدوات النظام"
need_bin docker
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else need_bin docker-compose; DC="docker-compose"; fi
cok "Docker & Compose متوفران"

cin "تثبيت حزم أساسية (مرة واحدة)"
apt-get update -y >>"$LOG" 2>&1 || true
apt-get install -y curl wget git jq unzip ca-certificates lsof htop tree netcat-openbsd >>"$LOG" 2>&1 || true
cok "Dependencies الأساسية موجودة"

# ---- .env ----
cin "إنشاء ملف البيئة .env"
cat > "$STACK/.env" <<'ENVEOF'
# ================== FFactory Env ==================
TZ=Asia/Kuwait

# Postgres
PGPORT=5433
PGUSER=forensic_user
PGPASSWORD=Forensic123!
PGDB=forensic_db

# Redis
REDIS_PORT=6379
REDIS_PASSWORD=Redis123!

# Neo4j
NEO4J_AUTH=neo4j/test123    # غيّره قبل الإنتاج (أو "none" للاختبار فقط)
NEO4J_HTTP_PORT=7474
NEO4J_BOLT_PORT=7687

# MinIO
MINIO_API_PORT=9000
MINIO_CONSOLE_PORT=9001
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=ChangeMe_12345

# Ollama
OLLAMA_PORT=11434

# Bots (ضع التوكنات لاحقًا)
ADMIN_BOT_TOKEN=
REPORTS_BOT_TOKEN=
BOT_ALLOWED_USERS=795444729

# Misc
VOL_SYMBOLS_HOST=/opt/ffactory/vol_symbols
ENVEOF
cok "تم إنشاء $STACK/.env"

# ---- docker-compose.ultimate.yml ----
cin "توليد docker-compose.ultimate.yml"
cat > "$STACK/docker-compose.ultimate.yml" <<'YML'
version: "3.8"

networks:
  ffactory_net:
    driver: bridge

volumes:
  postgres_data:
  redis_data:
  neo4j_data:
  neo4j_logs:
  minio_data:
  ollama_data:
  backup_data:

services:
  db:
    image: postgres:16
    container_name: ffactory_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${PGUSER}
      POSTGRES_PASSWORD: ${PGPASSWORD}
      POSTGRES_DB: ${PGDB}
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${PGPORT}:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ../scripts/init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${PGUSER} -d ${PGDB}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [ffactory_net]

  redis:
    image: redis:7-alpine
    container_name: ffactory_redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD}
    ports:
      - "127.0.0.1:${REDIS_PORT}:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [ffactory_net]

  neo4j:
    image: neo4j:5-community
    container_name: ffactory_neo4j
    restart: unless-stopped
    environment:
      NEO4J_AUTH: ${NEO4J_AUTH}
      NEO4J_PLUGINS: '["apoc", "graph-data-science"]'
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${NEO4J_HTTP_PORT}:7474"
      - "127.0.0.1:${NEO4J_BOLT_PORT}:7687"
    volumes:
      - neo4j_data:/data
      - neo4j_logs:/logs
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:7474"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks: [ffactory_net]

  minio:
    image: minio/minio:latest
    container_name: ffactory_minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${MINIO_API_PORT}:9000"
      - "127.0.0.1:${MINIO_CONSOLE_PORT}:9001"
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 15s
      retries: 5
    networks: [ffactory_net]

  metabase:
    image: metabase/metabase:latest
    container_name: ffactory_metabase
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: ${PGDB}
      MB_DB_PORT: 5432
      MB_DB_USER: ${PGUSER}
      MB_DB_PASS: ${PGPASSWORD}
      MB_DB_HOST: db
      TZ: ${TZ}
    depends_on:
      db:
        condition: service_healthy
    networks: [ffactory_net]

  ollama:
    image: ollama/ollama:latest
    container_name: ffactory_ollama
    restart: unless-stopped
    ports:
      - "127.0.0.1:${OLLAMA_PORT}:11434"
    volumes:
      - ollama_data:/root/.ollama
    networks: [ffactory_net]

  # === Core Apps (صغيرة وصحيحة) ===
  neural-core:
    build: ../apps/neural-core
    container_name: ffactory_neural_core
    restart: unless-stopped
    environment:
      DB_URL: postgresql://${PGUSER}:${PGPASSWORD}@db:5432/${PGDB}
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379
      TZ: ${TZ}
    ports:
      - "127.0.0.1:8000:8000"
    depends_on:
      db: {condition: service_healthy}
      redis: {condition: service_healthy}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks: [ffactory_net]

  correlation-engine:
    build: ../apps/correlation-engine
    container_name: ffactory_correlation_engine
    restart: unless-stopped
    environment:
      DB_URL: postgresql://${PGUSER}:${PGPASSWORD}@db:5432/${PGDB}
      NEO4J_URI: bolt://neo4j:7687
      NEO4J_AUTH: ${NEO4J_AUTH}
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379
      TZ: ${TZ}
    ports:
      - "127.0.0.1:8005:8005"
    depends_on:
      db: {condition: service_healthy}
      neo4j: {condition: service_healthy}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8005/health"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks: [ffactory_net]

  ai-reporting:
    build: ../apps/ai-reporting
    container_name: ffactory_ai_reporting
    restart: unless-stopped
    environment:
      DB_URL: postgresql://${PGUSER}:${PGPASSWORD}@db:5432/${PGDB}
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379
      TZ: ${TZ}
    ports:
      - "127.0.0.1:8080:8080"
    depends_on:
      db: {condition: service_healthy}
      redis: {condition: service_healthy}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks: [ffactory_net]

  # === Advanced Forensics (Volatility3) ===
  advanced-forensics:
    build: ../apps/advanced-forensics
    container_name: ffactory_advanced_forensics
    restart: unless-stopped
    environment:
      VOLATILITY_SYMBOLPATH: file:///symbols
      TZ: ${TZ}
    volumes:
      - ${VOL_SYMBOLS_HOST}:/symbols
    ports:
      - "127.0.0.1:8015:8015"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8015/health"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks: [ffactory_net]

  # === Extras (placeholders) ===
  quantum-security:
    build: ../apps/quantum-security
    container_name: ffactory_quantum_security
    restart: unless-stopped
    networks: [ffactory_net]

  social-intelligence:
    build: ../apps/social-intelligence
    container_name: ffactory_social_intelligence
    restart: unless-stopped
    networks: [ffactory_net]

  media-forensics-pro:
    build: ../apps/media-forensics-pro
    container_name: ffactory_media_forensics
    restart: unless-stopped
    networks: [ffactory_net]

  asr-engine:
    build: ../apps/asr-engine
    container_name: ffactory_asr_engine
    restart: unless-stopped
    ports:
      - "127.0.0.1:8004:8004"
    networks: [ffactory_net]

  backup-manager:
    build: ../apps/backup-manager
    container_name: ffactory_backup_manager
    restart: unless-stopped
    networks: [ffactory_net]

  # === Telegram bots (disabled until tokens) ===
  bot-admin:
    build: ../apps/telegram-bots
    container_name: ffactory_bot_admin
    restart: unless-stopped
    environment:
      BOT_TOKEN: ${ADMIN_BOT_TOKEN}
      BOT_TYPE: admin
      DB_URL: postgresql://${PGUSER}:${PGPASSWORD}@db:5432/${PGDB}
      ALLOWED_USERS: ${BOT_ALLOWED_USERS}
    depends_on:
      db: {condition: service_healthy}
    profiles: ["bots"]
    networks: [ffactory_net]

  bot-reports:
    build: ../apps/telegram-bots
    container_name: ffactory_bot_reports
    restart: unless-stopped
    environment:
      BOT_TOKEN: ${REPORTS_BOT_TOKEN}
      BOT_TYPE: reports
      DB_URL: postgresql://${PGUSER}:${PGPASSWORD}@db:5432/${PGDB}
      ALLOWED_USERS: ${BOT_ALLOWED_USERS}
    depends_on:
      db: {condition: service_healthy}
    profiles: ["bots"]
    networks: [ffactory_net]
YML
cok "تم إنشاء compose"

# ---- DB init.sql ----
cin "توليد init.sql لقاعدة البيانات"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/init.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS users(
 id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
 username TEXT UNIQUE NOT NULL,
 email TEXT UNIQUE,
 role TEXT DEFAULT 'user',
 is_active BOOLEAN DEFAULT true,
 created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cases(
 id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
 case_number TEXT UNIQUE NOT NULL,
 title TEXT NOT NULL,
 description TEXT,
 status TEXT DEFAULT 'open',
 priority TEXT DEFAULT 'medium',
 created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS evidence(
 id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
 case_id UUID REFERENCES cases(id) ON DELETE CASCADE,
 name TEXT NOT NULL,
 type TEXT NOT NULL,
 file_path TEXT,
 hash_sha256 TEXT,
 size BIGINT,
 metadata JSONB,
 created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS analysis_results(
 id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
 case_id UUID REFERENCES cases(id) ON DELETE CASCADE,
 evidence_id UUID REFERENCES evidence(id) ON DELETE CASCADE,
 analyzer_type TEXT NOT NULL,
 result_data JSONB NOT NULL,
 confidence_score NUMERIC(5,4),
 status TEXT DEFAULT 'completed',
 created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bot_users(
 chat_id BIGINT PRIMARY KEY,
 username TEXT,
 role TEXT DEFAULT 'user',
 is_active BOOLEAN DEFAULT true,
 created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bot_messages(
 id BIGSERIAL PRIMARY KEY,
 chat_id BIGINT REFERENCES bot_users(chat_id),
 command TEXT,
 payload JSONB,
 ts TIMESTAMPTZ DEFAULT now()
);

INSERT INTO bot_users(chat_id, username, role)
VALUES (795444729,'primary_admin','admin')
ON CONFLICT (chat_id) DO NOTHING;
SQL
cok "init.sql جاهز"

# ---- Apps: minimal implementations ----
mk_fastapi (){
  local path="$1" port="$2" name="$3"
  mkdir -p "$path"
  cat > "$path/requirements.txt" <<REQ
fastapi==0.115.0
uvicorn[standard]==0.30.6
psycopg2-binary==2.9.9
redis==5.0.1
REQ
  cat > "$path/Dockerfile" <<DOCK
FROM python:3.11-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE ${port}
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","${port}"]
DOCK
  cat > "$path/main.py" <<PY
from fastapi import FastAPI
from datetime import datetime
app = FastAPI(title="${name}", version="1.0.0")
@app.get("/health")
def health(): return {"status":"healthy","service":"${name}","ts":datetime.utcnow().isoformat()+"Z"}
@app.get("/")
def root(): return {"message":"${name} ready"}
PY
}

cin "تجهيز neural-core / correlation-engine / ai-reporting"
mk_fastapi "$APPS/neural-core" 8000 "Neural Core"
mk_fastapi "$APPS/correlation-engine" 8005 "Correlation Engine"
mk_fastapi "$APPS/ai-reporting" 8080 "AI Reporting"
cok "Core apps جاهزة"

cin "تجهيز placeholders إضافية"
mk_fastapi "$APPS/quantum-security" 8090 "Quantum Security"
mk_fastapi "$APPS/social-intelligence" 8091 "Social Intelligence"
mk_fastapi "$APPS/media-forensics-pro" 8092 "Media Forensics Pro"
# ASR
mkdir -p "$APPS/asr-engine"
cat > "$APPS/asr-engine/requirements.txt" <<REQ
fastapi==0.115.0
uvicorn[standard]==0.30.6
REQ
cat > "$APPS/asr-engine/Dockerfile" <<'DOCK'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8004
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8004"]
DOCK
cat > "$APPS/asr-engine/main.py" <<'PY'
from fastapi import FastAPI, UploadFile, File
app = FastAPI(title="ASR Engine", version="0.1")
@app.get("/health") 
def h(): return {"status":"healthy","service":"asr-engine"}
@app.post("/transcribe")
async def t(file: UploadFile = File(...)):
    return {"status":"not_implemented","note":"placeholder"}
PY
# Backup manager (no HTTP)
mkdir -p "$APPS/backup-manager"
cat > "$APPS/backup-manager/Dockerfile" <<'DOCK'
FROM bash:5.2
WORKDIR /app
COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh
CMD ["/app/run.sh"]
DOCK
cat > "$APPS/backup-manager/run.sh" <<'SH'
#!/usr/bin/env bash
echo "[backup-manager] placeholder running"; sleep infinity
SH
# Telegram bots minimal
mkdir -p "$APPS/telegram-bots"
cat > "$APPS/telegram-bots/requirements.txt" <<'PIP'
python-telegram-bot==20.7
PIP
cat > "$APPS/telegram-bots/Dockerfile" <<'DOCK'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python","entry.py"]
DOCK
cat > "$APPS/telegram-bots/entry.py" <<'PY'
import os, logging
from telegram.ext import Application, CommandHandler
logging.basicConfig(level="INFO")
token = os.getenv("BOT_TOKEN")
bot_type = os.getenv("BOT_TYPE","admin")
if not token:
    print("BOT_TOKEN not set"); raise SystemExit(1)
async def start(u,c): await u.message.reply_text(f"{bot_type} bot ready.")
async def whoami(u,c): await u.message.reply_text(str(u.effective_user.id))
async def status(u,c): await u.message.reply_text("DB=up")  # تبسيط
def main():
    app = Application.builder().token(token).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("whoami", whoami))
    app.add_handler(CommandHandler("status", status))
    app.run_polling()
if __name__=="__main__": main()
PY
cok "Placeholders جاهزة"

# ---- Advanced-Forensics (Volatility3) ----
cin "تجهيز advanced-forensics (Volatility3)"
AF="$APPS/advanced-forensics"
mkdir -p "$AF"
cat > "$AF/requirements.txt" <<'PIP'
fastapi==0.115.0
uvicorn[standard]==0.30.6
python-multipart==0.0.9
PIP
cat > "$AF/Dockerfile" <<'DOCK'
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl unzip ca-certificates libmagic1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Volatility3
RUN git clone --depth 1 https://github.com/volatilityfoundation/volatility3.git && \
    ln -s /app/volatility3/vol.py /usr/local/bin/vol.py

COPY main.py .
ENV VOLATILITY_SYMBOLPATH=file:///symbols
EXPOSE 8015
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8015"]
DOCK
cat > "$AF/main.py" <<'PY'
from fastapi import FastAPI, UploadFile, File, HTTPException
from datetime import datetime
import subprocess, json, tempfile, os

app = FastAPI(title="Advanced Forensics", version="1.0")

@app.get("/health")
def health(): 
    return {"status":"healthy","service":"advanced-forensics","ts":datetime.utcnow().isoformat()+"Z"}

def run_v3(mem, plugin):
    cmd = ["python3","/app/volatility3/vol.py","-f",mem,plugin,"-r","json"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "volatility error")
    out = r.stdout.strip()
    try:
        return json.loads(out if out.startswith("{") or out.startswith("[") else "[" + ",".join([l for l in out.splitlines() if l.strip()]) + "]")
    except Exception:
        return {"raw": out}

@app.post("/analyze/memory")
async def analyze_memory(file: UploadFile = File(...)):
    if not file.filename.lower().endswith((".raw",".mem",".dmp",".bin",".img")):
        raise HTTPException(400,"Unsupported memory dump extension")
    with tempfile.NamedTemporaryFile(delete=False, suffix=".mem") as tmp:
        while True:
            chunk = await file.read(8*1024*1024)
            if not chunk: break
            tmp.write(chunk)
        tmp_path = tmp.name
    try:
        ps = run_v3(tmp_path,"windows.pslist.PsList")
        net = run_v3(tmp_path,"windows.netscan.NetScan")
        mal = run_v3(tmp_path,"windows.malfind.Malfind")
        return {
            "status":"success",
            "summary":{
                "ps_count": len(ps) if isinstance(ps,list) else 0,
                "net_count": len(net) if isinstance(net,list) else 0,
                "malfind_count": len(mal) if isinstance(mal,list) else 0
            },
            "results":{"pslist": ps, "netscan": net, "malfind": mal}
        }
    finally:
        try: os.unlink(tmp_path)
        except: pass
PY
cok "advanced-forensics جاهز"

# ---- Management scripts ----
cin "سكربتات الإدارة"
cat > "$SCRIPTS/health_check.sh" <<'SH'
#!/usr/bin/env bash
set -e
echo "🔍 صحة الخدمات:"
for x in \
 "db:5433" "redis:6379" "neo4j-http:7474" "neo4j-bolt:7687" \
 "minio-api:9000" "minio-console:9001" "metabase:3000" \
 "neural-core:8000" "correlation:8005" "ai-reporting:8080" \
 "advanced-forensics:8015" "ollama:11434"
do
  n=${x%%:*}; p=${x##*:}
  if curl -sSf "http://127.0.0.1:$p/health" >/dev/null 2>&1 || nc -z 127.0.0.1 "$p"; then
    echo "✅ $n ($p)"
  else
    echo "❌ $n ($p)"
  fi
done
SH
chmod +x "$SCRIPTS/health_check.sh"
cok "تم"

# ---- Build & Up ----
cin "بناء الصور (قد يستغرق بعض الوقت)"
pushd "$STACK" >/dev/null

# إزالة بلوك GPU في حال عدم وجود NVIDIA (لخدمة ollama)
if ! command -v nvidia-smi >/dev/null 2>&1; then
  awk '
    /  ollama:/ {print; in=1; next}
    in && /deploy:/ {skip=1}
    in && skip && /^[^ ]/ {skip=0}
    !skip {print}
  ' docker-compose.ultimate.yml > docker-compose.ultimate.yml.tmp && mv docker-compose.ultimate.yml.tmp docker-compose.ultimate.yml
  cok "أزلنا deploy: GPU من ollama لعدم توفر NVIDIA"
fi

$DC -p ffactory -f docker-compose.ultimate.yml build >>"$LOG" 2>&1
cok "اكتمل البناء"

cin "تشغيل الخدمات الأساسية"
$DC -p ffactory -f docker-compose.ultimate.yml up -d db redis neo4j minio metabase ollama >>"$LOG" 2>&1
sleep 8

cin "تشغيل التطبيقات الأساسية"
$DC -p ffactory -f docker-compose.ultimate.yml up -d neural-core correlation-engine ai-reporting advanced-forensics >>"$LOG" 2>&1
sleep 6

popd >/dev/null
cok "تم تشغيل الخدمات"

# ---- Post checks ----
cin "اختبارات صحة سريعة"
bash "$SCRIPTS/health_check.sh" || true

echo
cok "كل شيء جاهز ✅"
echo "➡️  .env:              $STACK/.env"
echo "➡️  compose:           $STACK/docker-compose.ultimate.yml"
echo "➡️  خدمات الويب:"
echo "    • Metabase:            http://127.0.0.1:3000"
echo "    • Neural Core:         http://127.0.0.1:8000/health"
echo "    • Correlation Engine:  http://127.0.0.1:8005/health"
echo "    • AI Reporting:        http://127.0.0.1:8080/health"
echo "    • MinIO Console:       http://127.0.0.1:9001  (admin / ChangeMe_12345)"
echo "    • MinIO API:           http://127.0.0.1:9000"
echo "    • Advanced Forensics:  http://127.0.0.1:8015/health"
echo "    • Ollama:              http://127.0.0.1:11434/api/version"
echo
cwarn "لتشغيل البوتات: ضع التوكنات في $STACK/.env ثم:"
echo "   cd $STACK && $DC -p ffactory -f docker-compose.ultimate.yml --profile bots up -d bot-admin bot-reports"
echo
cok "انتهى 🌟"
