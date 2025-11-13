#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; APPS=$FF/apps; install -d -m 755 "$APPS"

stub(){ # name port
  local NAME="$1" PORT="$2"
  [[ -f "$APPS/$NAME/Dockerfile" ]] && { echo "skip $NAME"; return; }
  install -d "$APPS/$NAME"
  cat >"$APPS/$NAME/Dockerfile"<<D
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn
COPY . .
EXPOSE $PORT
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","$PORT"]
D
  cat >"$APPS/$NAME/main.py"<<PY
from fastapi import FastAPI
app=FastAPI(title="$NAME")
@app.get("/health")
def h(): return {"status":"ok","service":"$NAME"}
PY
}

# Generic stubs
for s in investigation-api behavioral-analytics feedback-api neural-core correlation-engine asr-engine social-intelligence quantum-security ai-reporting; do stub "$s" 8080; done
stub integrity-monitor 8100; stub anomaly-detector 8101; stub deception-detector 8102; stub social-analyzer 8103
stub chain-of-custody-manager 8105
stub advanced-steganalysis 8114; stub memory-forensics 8115; stub temporal-forensics 8116
stub media-forensics-pro 8001; stub medical-forensics 8010

# Orchestrator
if [[ ! -f "$APPS/orchestrator/Dockerfile" ]]; then
  install -d "$APPS/orchestrator"
  cat >"$APPS/orchestrator/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn httpx
COPY . .
EXPOSE 8060
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8060"]
D
  cat >"$APPS/orchestrator/main.py"<<'PY'
from fastapi import FastAPI
app = FastAPI(title="orchestrator")
@app.get("/health")
def h(): return {"status":"ok"}
PY
fi

# Ingest (مبسّط)
if [[ ! -f "$APPS/ingest-service/Dockerfile" ]]; then
  install -d "$APPS/ingest-service"
  cat >"$APPS/ingest-service/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn python-multipart
COPY . .
EXPOSE 8001
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8001"]
D
  cat >"$APPS/ingest-service/main.py"<<'PY'
from fastapi import FastAPI, UploadFile, Form, HTTPException
import hashlib
app = FastAPI(title="ingest-service")
@app.get("/health")
def h(): return {"status":"ok"}
@app.post("/upload/file")
async def upload(case_id: str = Form(...), file: UploadFile = Form(...)):
    data = await file.read()
    if not data: raise HTTPException(400, "empty file")
    sha = hashlib.sha256(data).hexdigest()
    return {"status":"QUEUED","job_id":sha,"case_id":case_id,"size":len(data)}
PY
fi

# Frontend (nginx بسيط)
if [[ ! -f "$APPS/frontend-dashboard/Dockerfile" ]]; then
  install -d "$APPS/frontend-dashboard"
  cat >"$APPS/frontend-dashboard/Dockerfile"<<'D'
FROM nginx:alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 3000
CMD ["nginx","-g","daemon off;"]
D
  cat >"$APPS/frontend-dashboard/nginx.conf"<<'NG'
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
  cat >"$APPS/frontend-dashboard/index.html"<<'HTML'
<!doctype html><meta charset="utf-8"><title>FFactory</title>
<body style="font-family:sans-serif"><h1>FFactory Dashboard</h1><p>Up & running.</p></body>
HTML
fi

# Bots placeholder
if [[ ! -f "$APPS/telegram-bots/Dockerfile" ]]; then
  install -d "$APPS/telegram-bots"
  cat >"$APPS/telegram-bots/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
CMD ["python","-c","print('bots placeholder')"]
D
fi

echo "stubs ready."
