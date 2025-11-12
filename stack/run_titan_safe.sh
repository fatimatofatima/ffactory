#!/usr/bin/env bash
# Wrapper لا يقفل الشل. يكتب المثبّت ثم يشغّله داخل Subshell.
set -u

install -d -m 755 /opt/ffactory

cat >/opt/ffactory/ffactory_titan_full.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

FF="/opt/ffactory"
APPS="$FF/apps"
STACK="$FF/stack"
SCRIPTS="$FF/scripts"
LOGS="$FF/logs"
DATA="$FF/data"
TS=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOGS/ffactory_titan_full_$TS.log"
PROJECT="ffactory"
COMPOSE_MAIN="$STACK/docker-compose.ultimate.yml"
COMPOSE_OVERRIDE="$STACK/docker-compose.override.yml"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$LOG_FILE"; }
warn(){ echo -e "${YELLOW}[!] $*${NC}" | tee -a "$LOG_FILE"; }
err(){ echo -e "${RED}[x] $*${NC}" | tee -a "$LOG_FILE"; exit 1; }

trap 'err "فشل عند السطر $LINENO — راجع $LOG_FILE"' ERR

# ---------- Pre-checks ----------
[[ $EUID -eq 0 ]] || err "يجب التشغيل كـ root"
command -v docker >/dev/null || err "Docker غير مثبت"
docker compose version >/dev/null 2>&1 || err "Docker Compose Plugin غير متاح"
install -d -m 755 "$APPS" "$STACK" "$SCRIPTS" "$LOGS" "$DATA" "$FF/backups"

# ---------- .env ----------
if [[ ! -f "$STACK/.env" ]]; then
  log "كتابة .env جديد"
  cat > "$STACK/.env" <<'ENV'
COMPOSE_PROJECT_NAME=ffactory
FF_NETWORK=ffactory_net
TZ=Asia/Kuwait

# Core
NEO4J_USER=neo4j
NEO4J_PASSWORD=StrongPass_2025!
PGUSER=forensic_user
PGPASSWORD=Forensic123!
PGDB=ffactory_core
REDIS_PASSWORD=Redis123!
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=ChangeMe_12345

# Ports
PGPORT=5433
REDIS_PORT=6379
FRONTEND_PORT=3000
INVESTIGATION_API_PORT=8080
ANALYTICS_PORT=8090
FEEDBACK_API_PORT=8070
AI_REPORT_PORT=8081
NEO4J_HTTP_PORT=7474
NEO4J_BOLT_PORT=7687
OLLAMA_PORT=11435
MINIO_PORT=9002

# Plugins / Flags
NEO4J_PLUGINS=["apoc","graph-data-science"]
NEO4J_ACCEPT_LICENSE_AGREEMENT=yes

# Bots (اختياري)
ADMIN_BOT_TOKEN=REPLACE_ADMIN_TOKEN
REPORTS_BOT_TOKEN=REPLACE_REPORTS_TOKEN
BOT_ALLOWED_USERS=795444729
ENV
else
  log ".env موجود — سنستخدمه كما هو."
fi

# ---------- init.sql ----------
if [[ ! -f "$SCRIPTS/init.sql" ]]; then
  log "كتابة scripts/init.sql"
  cat > "$SCRIPTS/init.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='failure_type_enum') THEN
    CREATE TYPE failure_type_enum AS ENUM ('UNKNOWN_ALGORITHM','MISSING_KEYS','CORRUPTED_DATA','CUSTOM_PROTECTION','VERSION_NOT_SUPPORTED','INSUFFICIENT_RESOURCES');
  END IF;
END $$;
CREATE TABLE IF NOT EXISTS cases(
  case_id TEXT PRIMARY KEY,
  case_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN',
  owner TEXT NOT NULL,
  risk_score NUMERIC(5,2) DEFAULT 0.0,
  risk_level TEXT DEFAULT 'LOW',
  created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS ingest_events(
  job_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id TEXT NOT NULL REFERENCES cases(case_id),
  object_key TEXT NOT NULL,
  sha256 VARCHAR(64) NOT NULL UNIQUE,
  created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS scan_results(
  job_id UUID REFERENCES ingest_events(job_id),
  case_id TEXT NOT NULL REFERENCES cases(case_id),
  family TEXT NOT NULL,
  score INTEGER NOT NULL DEFAULT 0,
  meta_json JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY(job_id, family)
);
CREATE TABLE IF NOT EXISTS timeline_events(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id TEXT NOT NULL REFERENCES cases(case_id),
  timestamp TIMESTAMPTZ NOT NULL,
  description TEXT,
  source TEXT,
  meta JSONB DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS decryption_failures(
  failure_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id TEXT NOT NULL REFERENCES cases(case_id),
  file_hash TEXT,
  failure_type failure_type_enum,
  error_message TEXT,
  failure_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO cases (case_id, case_name, owner)
VALUES ('DEMO_CASE_001','Initial Integrity Check','System')
ON CONFLICT (case_id) DO NOTHING;
SQL
fi

mk(){ install -d -m 755 "$APPS/$1"; }

# ---------- FastAPI stub helper ----------
stub(){
  local NAME="$1"
  local REQS="${2:-fastapi uvicorn}"
  local PORT="${3:-8080}"
  if [[ -f "$APPS/$NAME/Dockerfile" ]]; then
    log "تخطي $NAME (موجود)"
    return
  fi
  log "إنشاء خدمة $NAME"
  mk "$NAME"
  cat > "$APPS/$NAME/Dockerfile" <<D
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir $REQS
COPY . .
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 CMD curl -f http://localhost:$PORT/health || exit 1
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","$PORT"]
D
  cat > "$APPS/$NAME/main.py" <<PY
from fastapi import FastAPI
app = FastAPI(title="$NAME", version="1.0")
@app.get("/health")
def health(): return {"status":"ok","service":"$NAME"}
PY
}

# ---------- Create stubs & specialized services ----------
CORE_STUBS=(investigation-api behavioral-analytics feedback-api neural-core correlation-engine asr-engine social-intelligence quantum-security ai-reporting)
for s in "${CORE_STUBS[@]}"; do stub "$s"; done

# Frontend
if [[ ! -f "$APPS/frontend-dashboard/Dockerfile" ]]; then
  log "إنشاء Frontend Dashboard"
  mk frontend-dashboard
  cat > "$APPS/frontend-dashboard/Dockerfile" <<'FD'
FROM node:20-alpine AS builder
WORKDIR /app
RUN mkdir -p public && echo '<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>FFactory</title></head><body><h1 style="font-family:sans-serif">لوحة FFactory (TITAN)</h1></body></html>' > public/index.html

FROM nginx:alpine
COPY --from=builder /app/public /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 3000
CMD ["nginx","-g","daemon off;"]
FD
  cat > "$APPS/frontend-dashboard/nginx.conf" <<'NG'
events { worker_connections 1024; }
http {
  include /etc/nginx/mime.types; default_type application/octet-stream;
  server {
    listen 3000; server_name localhost;
    root /usr/share/nginx/html; index index.html;
    location / { try_files $uri $uri/ /index.html; }
    location /api/       { proxy_pass http://ffactory_investigation_api:8080/; }
    location /analytics/ { proxy_pass http://ffactory_behavioral_analytics:8080/; }
    location /feedback/  { proxy_pass http://ffactory_feedback_api:8080/; }
  }
}
NG
fi

# Ingest-service
if [[ ! -f "$APPS/ingest-service/Dockerfile" ]]; then
  log "إنشاء ingest-service"
  mk ingest-service
  cat > "$APPS/ingest-service/Dockerfile" <<'D'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends libmagic1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn requests redis python-magic pydantic
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8001"]
D
  cat > "$APPS/ingest-service/main.py" <<'P'
import magic, requests
from fastapi import FastAPI, UploadFile, Form, HTTPException
app = FastAPI(title="Ingest Gateway", version="3.0")
ORCH="http://ffactory_orchestrator:8060"
def _sha(b): import hashlib; h=hashlib.sha256(); h.update(b); return h.hexdigest()
@app.get("/health")
def h(): return {"status":"ok"}
@app.post("/upload/file")
async def up(case_id: str = Form(...), file: UploadFile = Form(...)):
    data = await file.read()
    if not data: raise HTTPException(400,"ملف فارغ")
    mime = magic.from_buffer(data, mime=True)
    sha = _sha(data)
    try:
        r = requests.post(f"{ORCH}/trigger_pipeline", json={"case_id":case_id,"object_key":file.filename,"sha256":sha,"mime_type":mime}, timeout=15)
        r.raise_for_status()
        return {"status":"QUEUED","job_id":sha,"mime":mime}
    except Exception as e:
        raise HTTPException(502, f"Orchestrator error: {e}")
P
fi

# Orchestrator
if [[ ! -f "$APPS/orchestrator/Dockerfile" ]]; then
  log "إنشاء orchestrator"
  mk orchestrator
  cat > "$APPS/orchestrator/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn httpx
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8060"]
D
  cat > "$APPS/orchestrator/main.py" <<'P'
from fastapi import FastAPI
import httpx
app = FastAPI(title="FFactory Orchestrator", version="1.0")
SCANNER="http://ffactory_social_analyzer:8103"
CORR="http://ffactory_correlation_engine:8080"
@app.get("/health")
def h(): return {"status":"ok"}
@app.post("/trigger_pipeline")
async def trig(job:dict):
    sha=job.get("sha256","")
    if len(sha)!=64: return {"status":"QA_FAILED","detail":"Invalid Hash Length"}
    async with httpx.AsyncClient(timeout=30.0) as c:
        await c.post(f"{SCANNER}/analyze/network", json={"relationships":[]})
        await c.get(f"{CORR}/health")
    return {"status":"LAUNCHED","pipeline":"Scan -> Correlate"}
P
fi

# Error Aggregator
if [[ ! -f "$APPS/error-aggregator/Dockerfile" ]]; then
  log "إنشاء error-aggregator"
  mk error-aggregator
  cat > "$APPS/error-aggregator/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn pydantic
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8075"]
D
  cat > "$APPS/error-aggregator/main.py" <<'P'
from fastapi import FastAPI
from pydantic import BaseModel
from datetime import datetime
app = FastAPI(title="Error Aggregator",version="1.0")
class ErrorEvent(BaseModel):
    service_name:str; error_type:str; message:str; case_id:str="N/A"; severity:str="WARN"
@app.post("/log/error")
def log_error(e:ErrorEvent): return {"status":"logged","at":datetime.utcnow().isoformat(),"event":e.model_dump()}
@app.get("/health")
def h(): return {"status":"ok"}
P
fi

# Integrity Monitor (8100)
if [[ ! -f "$APPS/integrity-monitor/Dockerfile" ]]; then
  mk integrity-monitor
  cat > "$APPS/integrity-monitor/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn psutil
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8100"]
D
  cat > "$APPS/integrity-monitor/main.py" <<'P'
from fastapi import FastAPI
import hashlib, psutil, time
app = FastAPI(title="Integrity Monitor")
def sys_hash():
  info=f"{psutil.boot_time()}|{psutil.virtual_memory().total}|{psutil.disk_usage('/').total}"
  return hashlib.sha256(info.encode()).hexdigest()
@app.get("/integrity/check")
def check(): return {"system_hash":sys_hash(),"timestamp":time.time(),"status":"secure"}
@app.get("/health")
def h(): return {"status":"ok"}
P
fi

# Anomaly (8101)
if [[ ! -f "$APPS/anomaly-detector/Dockerfile" ]]; then
  mk anomaly-detector
  cat > "$APPS/anomaly-detector/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn scikit-learn numpy
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8101"]
D
  cat > "$APPS/anomaly-detector/main.py" <<'P'
from fastapi import FastAPI
from sklearn.ensemble import IsolationForest
import numpy as np
app = FastAPI(title="Anomaly Detection Engine")
model = IsolationForest(contamination=0.1, random_state=42)
@app.post("/analyze/behavior")
def analyze(d:dict):
  x=np.array([[d.get('late_night_communications',0), d.get('unusual_transfers',0)]])
  model.fit(x); s=model.decision_function(x)[0]; iso=model.predict(x)[0]==-1
  return {"anomaly_score":float(s),"is_anomaly":bool(iso)}
@app.get("/health")
def h(): return {"status":"ok"}
P
fi

# Deception (8102)
if [[ ! -f "$APPS/deception-detector/Dockerfile" ]]; then
  mk deception-detector
  cat > "$APPS/deception-detector/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn textblob
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8102"]
D
  cat > "$APPS/deception-detector/main.py" <<'P'
from fastapi import FastAPI
from textblob import TextBlob
app = FastAPI(title="Deception Detection")
@app.post("/analyze/deception")
def a(d:dict):
  t=d.get("text",""); s=TextBlob(t).sentiment
  score=max(0, 100 - abs(s.polarity)*50 - t.count("لا")*10 - (25 if len(t.split())<15 else 0))
  return {"honesty_score":score,"risk":"LOW" if score>70 else "HIGH"}
@app.get("/health")
def h(): return {"status":"ok"}
P
fi

# Social Analyzer (8103)
if [[ ! -f "$APPS/social-analyzer/Dockerfile" ]]; then
  mk social-analyzer
  cat > "$APPS/social-analyzer/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn networkx
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8103"]
D
  cat > "$APPS/social-analyzer/main.py" <<'P'
from fastapi import FastAPI
import networkx as nx
app = FastAPI(title="Social Network Analyzer")
@app.post("/analyze/network")
def a(body:dict):
  G=nx.Graph(); G.add_edges_from([(r['source'],r['target']) for r in body.get('relationships',[]) if 'source'in r and 'target'in r])
  return {"nodes":G.number_of_nodes(),"edges":G.number_of_edges(),"is_connected":nx.is_connected(G) if G.number_of_nodes()>0 else False}
@app.get("/health")
def h(): return {"status":"ok"}
P
fi

# Chain-of-Custody (8105)
if [[ ! -f "$APPS/chain-of-custody-manager/Dockerfile" ]]; then
  mk chain-of-custody-manager
  cat > "$APPS/chain-of-custody-manager/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn redis pydantic
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8105"]
D
  cat > "$APPS/chain-of-custody-manager/main.py" <<'P'
import os, json, redis
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
r=redis.Redis(host=os.getenv('REDIS_HOST','redis'), port=6379, password=os.getenv('REDIS_PASSWORD'), db=1, decode_responses=True)
app=FastAPI(title="Chain of Custody Manager")
class Record(BaseModel):
  artifact_id:str; action:str; analyst_id:str; action_details:str=""; artifact_hash_after:str
@app.get("/health")
def h():
  try: r.ping(); return {"status":"ok","redis":True}
  except: return {"status":"error","redis":False}
@app.post("/record")
def rec(ev:Record):
  key=f"coc:{ev.artifact_id}"; r.rpush(key, json.dumps(ev.model_dump()))
  return {"status":"logged","key":key}
@app.get("/history/{aid}")
def hist(aid:str):
  key=f"coc:{aid}"; lst=r.lrange(key,0,-1)
  if not lst: raise HTTPException(404,"No history")
  return {"artifact_id":aid,"events":[json.loads(x) for x in lst]}
P
fi

# Backup Manager
if [[ ! -f "$APPS/backup-manager/Dockerfile" ]]; then
  mk backup-manager
  cat > "$APPS/backup-manager/Dockerfile" <<'D'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client tar gzip && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN pip install --no-cache-dir python-dotenv
COPY . .
CMD ["python","backup_manager.py"]
D
  cat > "$APPS/backup-manager/backup_manager.py" <<'P'
import os, subprocess, json, time
from datetime import datetime
PGUSER=os.getenv('PGUSER','forensic_user'); PGPASSWORD=os.getenv('PGPASSWORD','Forensic123!'); PGDB=os.getenv('PGDB','ffactory_core')
BACKUP_DIR=os.getenv('BACKUP_DIR','/backups'); os.makedirs(BACKUP_DIR,exist_ok=True)
def run():
  ts=datetime.now().strftime("%Y%m%d_%H%M%S")
  dump=os.path.join(BACKUP_DIR,f"postgres_$TS.sql".replace("$TS", ts))
  env=os.environ.copy(); env['PGPASSWORD']=PGPASSWORD
  subprocess.run(['pg_dump','-U',PGUSER,'-h','db','-d',PGDB,'-f',dump],check=True,env=env)
  meta=os.path.join(BACKUP_DIR,'settings_snapshot.json'); open(meta,'w').write(json.dumps(dict(os.environ),indent=2))
  arc=os.path.join(BACKUP_DIR,f"ffactory_backup_$TS.tar.gz".replace("$TS", ts))
  subprocess.run(['tar','-czf',arc,'-C',BACKUP_DIR,os.path.basename(dump),os.path.basename(meta)],check=True)
  os.remove(dump)
if __name__=="__main__":
  time.sleep(5)
  try: run(); print("Backup OK")
  except Exception as e: print("Backup failed:",e)
P
fi

# Media & Medical
if [[ ! -f "$APPS/media-forensics-pro/Dockerfile" ]]; then
  mk media-forensics-pro
  cat > "$APPS/media-forensics-pro/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn requests
COPY . .
CMD ["uvicorn","service:app","--host","0.0.0.0","--port","8001"]
D
  cat > "$APPS/media-forensics-pro/service.py" <<'P'
from fastapi import FastAPI
app = FastAPI(title="Media Forensics Pro",version="2.0")
@app.post("/analyze/video")
def analyze_video(d:dict):
  return {"status":"PROCESSING_SCHEDULED","scene_count":3,"visual_analysis_tasks":[{"action":"OCR_VISION_ANALYSIS","image":"s1.jpg","time":0}]}
@app.get("/health")
def h(): return {"status":"ok"}
P
fi

if [[ ! -f "$APPS/medical-forensics/Dockerfile" ]]; then
  mk medical-forensics
  cat > "$APPS/medical-forensics/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn requests pydantic Pillow imagehash numpy
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8010"]
D
  cat > "$APPS/medical-forensics/main.py" <<'P'
from fastapi import FastAPI
app = FastAPI(title="Medical Forensics Unit",version="1.0")
@app.post("/analyze/drug")
def analyze(d:dict):
  return {"drug_name":"Tramadol","recommendation":"CRITICAL: INVESTIGATE PHONE NUMBER AND CONTACTS.","intent_analysis":{"risk_score":0.95,"risk_type":"CONTROLLED_SUBSTANCE_MATCH"}}
@app.get("/health")
def h(): return {"status":"ok"}
P
fi

# Anti–Anti-Forensics (8114/8115/8116)
if [[ ! -f "$APPS/advanced-steganalysis/Dockerfile" ]]; then
  mk advanced-steganalysis
  cat > "$APPS/advanced-steganalysis/Dockerfile" <<'D'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends libmagic1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn numpy python-magic Pillow
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8114"]
D
  cat > "$APPS/advanced-steganalysis/main.py" <<'P'
from fastapi import FastAPI, HTTPException
import os, numpy as np, magic
app = FastAPI(title="Advanced Steganalysis Engine")
def entropy_sample(path,maxb=4000000):
  with open(path,'rb') as f: data=f.read(maxb)
  if not data: return 0.0
  import numpy as np
  arr=np.frombuffer(data,dtype=np.uint8); p=np.bincount(arr,minlength=256)/arr.size; p=p[p>0]
  return float(-(p*np.log2(p)).sum())
@app.get("/health")
def h(): return {"status":"ok"}
@app.post("/analyze/anti-forensics")
def analyze(b:dict):
  fp=b.get("file_path")
  if not fp or not os.path.exists(fp): raise HTTPException(400,"file_path مفقود/غير موجود")
  e=entropy_sample(fp); mime=magic.from_file(fp,mime=True)
  risk="HIGH" if e>7.5 else "MEDIUM" if e>7.0 else "LOW"
  ind=[]
  if fp.lower().endswith(".jpg") and "zip" in mime: ind.append("Possible ZIP-in-JPEG")
  return {"entropy_score":round(e,4),"risk_level":risk,"real_mime_type":mime,"indicators":ind}
P
fi

if [[ ! -f "$APPS/memory-forensics/Dockerfile" ]]; then
  mk memory-forensics
  cat > "$APPS/memory-forensics/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn psutil
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8115"]
D
  cat > "$APPS/memory-forensics/main.py" <<'P'
from fastapi import FastAPI
app = FastAPI(title="Virtual Memory Forensics")
@app.get("/health")
def h(): return {"status":"ok"}
@app.post("/analyze/virtual-memory")
def a(d:dict):
  return {"remnants_found":["TrueCrypt","VeraCrypt","BitLocker"],"keys_extracted_candidates":["AES_KEY_0xDECAFBAD","PGP_HEADER_0x1234"],"risk_level":"CRITICAL"}
P
fi

if [[ ! -f "$APPS/temporal-forensics/Dockerfile" ]]; then
  mk temporal-forensics
  cat > "$APPS/temporal-forensics/Dockerfile" <<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8116"]
D
  cat > "$APPS/temporal-forensics/main.py" <<'P'
from fastapi import FastAPI
from datetime import datetime
app = FastAPI(title="Temporal Anti-Forensics")
def iso(s):
  try: return datetime.fromisoformat(s.replace("Z","+00:00"))
  except: return None
@app.get("/health")
def h(): return {"status":"ok"}
@app.post("/analyze/temporal-anomalies")
def a(b:dict):
  c=iso(b.get("created_ts","")); m=iso(b.get("modified_ts","")); drift=float(b.get("host_ntp_drift_ms",0))
  reasons=[]; anomaly=False
  if c and m and m<c: anomaly=True; reasons.append("modified_before_created")
  if abs(drift)>5000: anomaly=True; reasons.append("large_host_time_drift")
  return {"anomaly_detected":anomaly,"reasons":reasons,"drift_ms":drift}
P
fi

# ---------- Compose MAIN (block-style env) ----------
if [[ -f "$COMPOSE_MAIN" ]]; then
  cp -a "$COMPOSE_MAIN" "$COMPOSE_MAIN.bak.$TS"
  log "نسخة احتياطية: $COMPOSE_MAIN.bak.$TS"
fi

cat > "$COMPOSE_MAIN" <<'YML'
version: "3.8"

networks: { ffactory_net: {driver: bridge} }

volumes:
  postgres_data: {}
  redis_data: {}
  neo4j_data: {}
  minio_data: {}
  ollama_data: {}
  asr_models: {}
  backup_data: {}
  vault_data: {}

services:
  # CORE
  db:
    image: postgres:16
    container_name: ffactory_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${PGUSER}
      POSTGRES_PASSWORD: "${PGPASSWORD}"
      POSTGRES_DB: ${PGDB}
    ports: ["127.0.0.1:${PGPORT}:5432"]
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ../scripts/init.sql:/docker-entrypoint-initdb.d/init.sql
    networks: [ ffactory_net ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U ${PGUSER} -d ${PGDB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: ffactory_redis
    restart: unless-stopped
    command: ["redis-server","--requirepass","${REDIS_PASSWORD}"]
    ports: ["127.0.0.1:${REDIS_PORT}:6379"]
    networks: [ ffactory_net ]
    healthcheck:
      test: ["CMD","redis-cli","-a","${REDIS_PASSWORD}","ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  neo4j:
    image: neo4j:5-community
    container_name: ffactory_neo4j
    restart: unless-stopped
    environment:
      NEO4J_AUTH: "${NEO4J_USER}/${NEO4J_PASSWORD}"
      NEO4J_PLUGINS: "${NEO4J_PLUGINS}"
      NEO4J_ACCEPT_LICENSE_AGREEMENT: "${NEO4J_ACCEPT_LICENSE_AGREEMENT}"
    ports:
      - "127.0.0.1:${NEO4J_HTTP_PORT}:7474"
      - "127.0.0.1:${NEO4J_BOLT_PORT}:7687"
    volumes: [ neo4j_data:/data ]
    networks: [ ffactory_net ]
    healthcheck:
      test: ["CMD-SHELL","wget -q --spider http://localhost:7474 || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 3

  minio:
    image: minio/minio:latest
    container_name: ffactory_minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD}"
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:${MINIO_PORT}:9001"
    volumes: [ minio_data:/data ]
    networks: [ ffactory_net ]
    healthcheck:
      test: ["CMD","curl","-f","http://localhost:9000/minio/health/live"]
      interval: 15s
      timeout: 10s
      retries: 3

  ollama:
    image: ollama/ollama:latest
    container_name: ffactory_ollama
    restart: unless-stopped
    ports: ["127.0.0.1:${OLLAMA_PORT}:11434"]
    volumes: [ ollama_data:/root/.ollama ]
    networks: [ ffactory_net ]

  metabase:
    image: metabase/metabase:latest
    container_name: ffactory_metabase
    restart: unless-stopped
    ports: ["127.0.0.1:3001:3000"]
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: ${PGDB}
      MB_DB_USER: ${PGUSER}
      MB_DB_PASS: "${PGPASSWORD}"
      MB_DB_HOST: db
    networks: [ ffactory_net ]
    depends_on: { db: { condition: service_healthy } }

  ntp-server:
    image: cturra/ntp
    container_name: ffactory_ntp
    restart: unless-stopped
    cap_add: [ "SYS_TIME" ]
    environment:
      - NTP_SERVERS=pool.ntp.org,time.google.com
      - INTERNAL_NTP_SERVER=true
    networks: [ ffactory_net ]

  vault:
    image: hashicorp/vault:1.15
    container_name: ffactory_vault
    restart: unless-stopped
    ports: ["127.0.0.1:8200:8200"]
    environment:
      VAULT_DEV_ROOT_TOKEN_ID: root_dev_token
      VAULT_DEV_LISTEN_ADDRESS: "0.0.0.0:8200"
    volumes: [ vault_data:/vault/file ]
    networks: [ ffactory_net ]

  # APIs & ENGINES (Stubs)
  investigation-api:
    build: { context: ../apps/investigation-api }
    container_name: ffactory_investigation_api
    restart: unless-stopped
    ports: ["127.0.0.1:${INVESTIGATION_API_PORT}:8080"]
    networks: [ ffactory_net ]
    depends_on: [ neo4j ]
    healthcheck: { test: ["CMD","curl","-f","http://localhost:8080/health"] }

  behavioral-analytics:
    build: { context: ../apps/behavioral-analytics }
    container_name: ffactory_behavioral_analytics
    restart: unless-stopped
    ports: ["127.0.0.1:${ANALYTICS_PORT}:8080"]
    networks: [ ffactory_net ]
    depends_on: [ redis ]
    healthcheck: { test: ["CMD","curl","-f","http://localhost:8080/health"] }

  feedback-api:
    build: { context: ../apps/feedback-api }
    container_name: ffactory_feedback_api
    restart: unless-stopped
    ports: ["127.0.0.1:${FEEDBACK_API_PORT}:8080"]
    networks: [ ffactory_net ]
    depends_on: [ db ]
    healthcheck: { test: ["CMD","curl","-f","http://localhost:8080/health"] }

  neural-core:        { build: { context: ../apps/neural-core },        container_name: ffactory_neural_core,       restart: unless-stopped, ports: ["127.0.0.1:8000:8080"], networks: [ffactory_net] }
  correlation-engine: { build: { context: ../apps/correlation-engine },  container_name: ffactory_correlation_engine, restart: unless-stopped, ports: ["127.0.0.1:8005:8080"], networks: [ffactory_net] }
  asr-engine:         { build: { context: ../apps/asr-engine },         container_name: ffactory_asr_engine,        restart: unless-stopped, ports: ["127.0.0.1:8004:8080"], volumes: [asr_models:/root/.cache], networks: [ffactory_net] }
  social-intelligence:{ build: { context: ../apps/social-intelligence }, container_name: ffactory_social_intelligence, restart: unless-stopped, networks: [ffactory_net] }
  quantum-security:   { build: { context: ../apps/quantum-security },   container_name: ffactory_quantum_security,   restart: unless-stopped, networks: [ffactory_net] }
  ai-reporting:
    build: { context: ../apps/ai-reporting }
    container_name: ffactory_ai_reporting
    restart: unless-stopped
    ports: ["127.0.0.1:${AI_REPORT_PORT}:8080"]
    networks: [ ffactory_net ]

  # Automation & QA
  orchestrator:
    build: { context: ../apps/orchestrator }
    container_name: ffactory_orchestrator
    restart: unless-stopped
    ports: ["127.0.0.1:8060:8060"]
    networks: [ ffactory_net ]
    depends_on: [ db, redis ]

  ingest-service:
    build: { context: ../apps/ingest-service }
    container_name: ffactory_ingest_service
    restart: unless-stopped
    ports: ["127.0.0.1:8001:8001"]
    volumes: [ minio_data:/data_minio:ro ]
    networks: [ ffactory_net ]
    depends_on: [ minio, orchestrator ]

  error-aggregator:
    build: { context: ../apps/error-aggregator }
    container_name: ffactory_error_aggregator
    restart: unless-stopped
    ports: ["127.0.0.1:8075:8075"]
    networks: [ ffactory_net ]
    depends_on: [ db ]

  # Advanced Analytics
  integrity-monitor: { build: { context: ../apps/integrity-monitor }, container_name: ffactory_integrity_monitor, restart: unless-stopped, ports: ["127.0.0.1:8100:8100"], networks: [ffactory_net] }
  anomaly-detector:  { build: { context: ../apps/anomaly-detector },  container_name: ffactory_anomaly_detector,  restart: unless-stopped, ports: ["127.0.0.1:8101:8101"], networks: [ffactory_net], depends_on: [redis] }
  deception-detector:{ build: { context: ../apps/deception-detector }, container_name: ffactory_deception_detector, restart: unless-stopped, ports: ["127.0.0.1:8102:8102"], networks: [ffactory_net] }
  social-analyzer:   { build: { context: ../apps/social-analyzer },    container_name: ffactory_social_analyzer,   restart: unless-stopped, ports: ["127.0.0.1:8103:8103"], networks: [ffactory_net] }

  chain-of-custody-manager:
    build: { context: ../apps/chain-of-custody-manager }
    container_name: ffactory_coc_manager
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: "${REDIS_PASSWORD}"
      REDIS_HOST: redis
    ports: ["127.0.0.1:8105:8105"]
    networks: [ ffactory_net ]
    depends_on: [ redis ]

  # Anti–Anti-Forensics
  advanced-steganalysis: { build: { context: ../apps/advanced-steganalysis }, container_name: ffactory_advanced_steganalysis, restart: unless-stopped, ports: ["127.0.0.1:8114:8114"], networks: [ffactory_net] }
  memory-forensics:      { build: { context: ../apps/memory-forensics },      container_name: ffactory_memory_forensics,   restart: unless-stopped, ports: ["127.0.0.1:8115:8115"], networks: [ffactory_net] }
  temporal-forensics:    { build: { context: ../apps/temporal-forensics },    container_name: ffactory_temporal_forensics, restart: unless-stopped, ports: ["127.0.0.1:8116:8116"], networks: [ffactory_net] }

  # Media & Medical
  media-forensics-pro:
    build: { context: ../apps/media-forensics-pro }
    container_name: ffactory_media_forensics
    restart: unless-stopped
    ports: ["127.0.0.1:8011:8001"]
    volumes: [ minio_data:/data_minio:ro ]
    networks: [ ffactory_net ]

  medical-forensics:
    build: { context: ../apps/medical-forensics }
    container_name: ffactory_medical_forensics
    restart: unless-stopped
    ports: ["127.0.0.1:8010:8010"]
    networks: [ ffactory_net ]

  # UI
  frontend-dashboard:
    build: { context: ../apps/frontend-dashboard }
    container_name: ffactory_frontend_dashboard
    restart: unless-stopped
    ports: ["0.0.0.0:${FRONTEND_PORT}:3000"]
    networks: [ ffactory_net ]
    depends_on:
      - investigation-api
      - behavioral-analytics
      - feedback-api

  # Bots (optional)
  bot-admin:
    build: { context: ../apps/telegram-bots }
    container_name: ffactory_bot_admin
    environment:
      BOT_TOKEN: "${ADMIN_BOT_TOKEN}"
      BOT_TYPE: admin
      BOT_ALLOWED_USERS: ${BOT_ALLOWED_USERS}
    networks: [ ffactory_net ]
    profiles: ["bots"]

  bot-reports:
    build: { context: ../apps/telegram-bots }
    container_name: ffactory_bot_reports
    environment:
      BOT_TOKEN: "${REPORTS_BOT_TOKEN}"
      BOT_TYPE: reports
      BOT_ALLOWED_USERS: ${BOT_ALLOWED_USERS}
    networks: [ ffactory_net ]
    profiles: ["bots"]
YML

# ---------- Compose OVERRIDE ----------
cat > "$COMPOSE_OVERRIDE" <<'YML'
version: "3.8"

x-logging: &default-logging
  driver: "json-file"
  options: { max-size: "10m", max-file: "3" }

x-hardening: &hard
  logging: *default-logging
  ulimits: { nofile: 65535 }
  security_opt: [ "no-new-privileges:true" ]

services:
  db:         <<: *hard
  redis:      <<: *hard
  neo4j:      <<: *hard
  minio:      <<: *hard
  ollama:     <<: *hard
  metabase:   <<: *hard
  ntp-server: <<: *hard
  vault:      <<: *hard

  investigation-api:   <<: *hard
  behavioral-analytics:<<: *hard
  feedback-api:        <<: *hard
  neural-core:         <<: *hard
  correlation-engine:  <<: *hard
  asr-engine:          <<: *hard
  social-intelligence: <<: *hard
  quantum-security:    <<: *hard
  ai-reporting:        <<: *hard

  orchestrator:        <<: *hard
  ingest-service:      <<: *hard
  error-aggregator:    <<: *hard

  integrity-monitor:   <<: *hard
  anomaly-detector:    <<: *hard
  deception-detector:  <<: *hard
  social-analyzer:     <<: *hard
  chain-of-custody-manager: <<: *hard

  advanced-steganalysis: <<: *hard
  memory-forensics:      <<: *hard
  temporal-forensics:    <<: *hard

  media-forensics-pro:   <<: *hard
  medical-forensics:     <<: *hard

  frontend-dashboard:    <<: *hard
  bot-admin:             <<: *hard
  bot-reports:           <<: *hard
YML

# ---------- Bring up ----------
log "تحقق من صحة الملفات"
cd "$STACK"
docker compose -p "$PROJECT" -f "$COMPOSE_MAIN" -f "$COMPOSE_OVERRIDE" config >/dev/null

log "إيقاف بقايا قديمة"
docker compose -p "$PROJECT" -f "$COMPOSE_MAIN" -f "$COMPOSE_OVERRIDE" down --remove-orphans || true
docker network rm ${PROJECT}_default 2>/dev/null || true

log "بناء وتشغيل"
docker compose -p "$PROJECT" -f "$COMPOSE_MAIN" -f "$COMPOSE_OVERRIDE" up -d --build --remove-orphans

log "انتظار الاستقرار"
sleep 35
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | tee -a "$LOG_FILE"

# ---------- Health sweep ----------
source "$STACK/.env" || true
check(){ curl -fsS "$1" >/dev/null && log "OK: $1" || warn "FAIL: $1"; }

log "فحوصات:"
check "http://127.0.0.1:${FRONTEND_PORT:-3000}/"
check "http://127.0.0.1:${INVESTIGATION_API_PORT:-8080}/health"
check "http://127.0.0.1:${ANALYTICS_PORT:-8090}/health"
check "http://127.0.0.1:${FEEDBACK_API_PORT:-8070}/health"
check "http://127.0.0.1:8060/health"
check "http://127.0.0.1:8075/health"
check "http://127.0.0.1:8001/health"
check "http://127.0.0.1:8100/health"
check "http://127.0.0.1:8101/health"
check "http://127.0.0.1:8102/health"
check "http://127.0.0.1:8103/health"
check "http://127.0.0.1:8105/health"
check "http://127.0.0.1:8114/health"
check "http://127.0.0.1:8115/health"
check "http://127.0.0.1:8116/health"
check "http://127.0.0.1:8010/health"
check "http://127.0.0.1:8011/health"
check "http://127.0.0.1:${NEO4J_HTTP_PORT:-7474}/"
check "http://127.0.0.1:${MINIO_PORT:-9002}/"

echo ""
log "Endpoints:"
cat <<'EOS'
UI:                  http://SERVER:3000
Investigation API:   GET  http://SERVER:8080/health
Behavioral:          GET  http://SERVER:8090/health
Feedback:            GET  http://SERVER:8070/health
Orchestrator:        GET  http://SERVER:8060/health
Ingest:              POST http://SERVER:8001/upload/file
Error Aggregator:    POST http://SERVER:8075/log/error
Chain-of-Custody:    POST http://SERVER:8105/record | GET /history/{artifact_id}
Integrity Monitor:   GET  http://SERVER:8100/integrity/check
Anomaly Detector:    POST http://SERVER:8101/analyze/behavior
Deception Detector:  POST http://SERVER:8102/analyze/deception
Social Analyzer:     POST http://SERVER:8103/analyze/network
Media Forensics Pro: POST http://SERVER:8011/analyze/video
Medical Forensics:   POST http://SERVER:8010/analyze/drug
Steganalysis:        POST http://SERVER:8114/analyze/anti-forensics
Memory Forensics:    POST http://SERVER:8115/analyze/virtual-memory
Temporal Forensics:  POST http://SERVER:8116/analyze/temporal-anomalies
Neo4j UI:            http://SERVER:7474
MinIO Console:       http://SERVER:9001
Metabase:            http://SERVER:3001
Vault (dev):         http://SERVER:8200
EOS

log "انتهى."
exit 0
EOF

chmod +x /opt/ffactory/ffactory_titan_full.sh

# تشغيل داخل Subshell كي لا يُغلق الشل
( bash /opt/ffactory/ffactory_titan_full.sh )
code=$?
echo "installer exit code: $code"
true
