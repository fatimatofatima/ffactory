#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory; APPS=$FF/apps; STACK=$FF/stack; NET=ffactory_ffactory_net; ENV=$FF/.env
[ -f "$ENV" ] || die ".env مفقود"; docker network inspect "$NET" >/dev/null 2>&1 || die "الشبكة $NET مفقودة"
install -d -m 755 "$APPS/social-archive" "$APPS/video-metadata" "$APPS/social-linker" "$STACK"

sanitize(){ [ -f "$1" ] || return 0; tr '\240' ' ' <"$1" | tr -d '\r' >"$1.__c" && mv -f "$1.__c" "$1"; }

# ===== social-archive: تحليل أرشيفات المنصات إلى Postgres =====
cat >"$APPS/social-archive/requirements.txt"<<'R'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
psycopg[binary,pool]>=3.2
python-dateutil>=2.9
R
cat >"$APPS/social-archive/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from dateutil import parser as dtp
import os, io, json, zipfile, tempfile, requests, psycopg
api=FastAPI()

DBH=os.getenv("DB_HOST","db"); DBP=int(os.getenv("DB_PORT","5432"))
DBN=os.getenv("POSTGRES_DB","ffactory"); DBU=os.getenv("POSTGRES_USER","ffadmin"); DBPW=os.getenv("POSTGRES_PASSWORD")
def db(): return psycopg.connect(host=DBH, port=DBP, dbname=DBN, user=DBU, password=DBPW)

def ensure_schema():
    with db() as c, c.cursor() as cur:
        cur.execute("""
        CREATE TABLE IF NOT EXISTS sm_accounts(
          id BIGSERIAL PRIMARY KEY, platform TEXT, handle TEXT, name TEXT, external_id TEXT UNIQUE, extra JSONB);
        CREATE TABLE IF NOT EXISTS sm_messages(
          id BIGSERIAL PRIMARY KEY, platform TEXT, ts TIMESTAMPTZ, author TEXT, peer TEXT, text TEXT, media JSONB, extra JSONB);
        CREATE TABLE IF NOT EXISTS sm_media(
          id BIGSERIAL PRIMARY KEY, platform TEXT, ts TIMESTAMPTZ, path TEXT, url TEXT, type TEXT, extra JSONB);
        """); c.commit()

def _ts(x):
    if not x: return None
    try: return dtp.parse(x)
    except: 
        try: return dtp.parse(str(x/1000.0))
        except: return None

class Inp(BaseModel):
    zip_url:str
    platform:str|None=None      # telegram|twitter|facebook|instagram|auto
    store:bool|None=True        # تخزين للجدول

@api.get("/health")
def health():
    try:
        with db() as c: c.execute("SELECT 1;")
        return {"status":"ok","db":"ready"}
    except Exception as e:
        return {"status":"degraded","db_error":str(e)}

def parse_telegram(zf):
    # توقع Telegram Desktop export: result.json
    try:
        with zf.open("result.json") as f:
            data=json.load(f)
    except KeyError: 
        return []
    out=[]
    chats=data.get("chats",{}).get("list",[])
    for ch in chats:
        name=ch.get("name")
        for m in ch.get("messages",[]):
            if m.get("type")!="message": continue
            out.append({
                "platform":"telegram","ts":_ts(m.get("date")), "author":m.get("from",""),
                "peer":name, "text":m.get("text") if isinstance(m.get("text"),str) else str(m.get("text")),
                "media":None, "extra":{"id":m.get("id")}
            })
    return out

def _read_text(zf, path):
    with zf.open(path) as f: return f.read().decode("utf-8","ignore")

def parse_twitter(zf):
    # توقع Tweets.js أو data/tweets.js
    for p in zf.namelist():
        if p.endswith("tweets.js") or p.endswith("tweet.js"):
            raw=_read_text(zf,p)
            idx=raw.find("=")
            js=raw[idx+1:].strip() if idx!=-1 else raw
            arr=json.loads(js)
            out=[]
            for it in arr:
                tw=it.get("tweet",it)
                out.append({"platform":"twitter","ts":_ts(tw.get("created_at")),
                            "author":tw.get("user_id_str",""),"peer":None,"text":tw.get("full_text") or tw.get("text"),
                            "media":None,"extra":{"id":tw.get("id_str")}})
            return out
    return []

def parse_facebook(zf):
    # رسائل في messages/inbox/*/*.json
    out=[]
    for p in zf.namelist():
        if "/messages/inbox/" in p and p.endswith(".json"):
            try:
                msgs=json.loads(_read_text(zf,p)).get("messages",[])
            except: 
                continue
            for m in msgs:
                out.append({"platform":"facebook","ts":_ts(m.get("timestamp_ms")),
                            "author":m.get("sender_name"),"peer":None,"text":m.get("content"),
                            "media":None,"extra":{"type":m.get("type")}})
    return out

def parse_instagram(zf):
    # رسائل في messages/inbox/*/message_1.json
    out=[]
    for p in zf.namelist():
        if "/messages/inbox/" in p and p.endswith("message_1.json"):
            try:
                msgs=json.loads(_read_text(zf,p))
            except: 
                continue
            for m in msgs:
                out.append({"platform":"instagram","ts":_ts(m.get("timestamp_ms")),
                            "author":m.get("sender_name"),"peer":None,"text":m.get("text"),
                            "media":None,"extra":{}})
    return out

@api.post("/parse_archive")
def parse_archive(inp:Inp):
    ensure_schema()
    r=requests.get(inp.zip_url, timeout=60); r.raise_for_status()
    with tempfile.NamedTemporaryFile(suffix=".zip") as f:
        f.write(r.content); f.flush()
        with zipfile.ZipFile(f.name) as zf:
            platform=(inp.platform or "auto").lower()
            rows=[]
            if platform=="telegram" or platform=="auto":
                rows=parse_telegram(zf)
                if rows: platform="telegram"
            if not rows and (platform=="twitter" or platform=="auto"):
                rows=parse_twitter(zf); 
            if not rows and (platform=="facebook" or platform=="auto"):
                rows=parse_facebook(zf)
            if not rows and (platform=="instagram" or platform=="auto"):
                rows=parse_instagram(zf)
    if not rows: raise HTTPException(400,"لم يتم التعرف على محتوى الأرشيف")
    inserted=0
    if inp.store:
        with db() as c, c.cursor() as cur:
            for r2 in rows:
                cur.execute("""INSERT INTO sm_messages(platform,ts,author,peer,text,media,extra)
                               VALUES(%s,%s,%s,%s,%s,%s,%s)""",
                            (r2["platform"], r2["ts"], r2["author"], r2["peer"], r2["text"], None, r2.get("extra")))
            inserted=len(rows); c.commit()
    return {"platform":rows[0]["platform"],"count":len(rows),"inserted":inserted}
PY
cat >"$APPS/social-archive/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
D
sanitize "$APPS/social-archive/Dockerfile"

# ===== video-metadata: ffprobe للفيديو عن بعد =====
cat >"$APPS/video-metadata/requirements.txt"<<'R'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
R
cat >"$APPS/video-metadata/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess, json, shutil
api=FastAPI()
def ffprobe_ok(): return shutil.which("ffprobe") is not None
@api.get("/health")
def health(): return {"status":"ok" if ffprobe_ok() else "bad", "ffprobe": bool(ffprobe_ok())}
class Inp(BaseModel): url:str
@api.post("/probe")
def probe(inp:Inp):
    if not ffprobe_ok(): raise HTTPException(500,"ffprobe not found")
    cmd=["ffprobe","-v","error","-show_format","-show_streams","-of","json",inp.url]
    p=subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode!=0: raise HTTPException(400, p.stderr.strip())
    return json.loads(p.stdout)
PY
cat >"$APPS/video-metadata/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
D
sanitize "$APPS/video-metadata/Dockerfile"

# ===== social-linker: ربط حسابات بمن عُرّف في Neo4j =====
cat >"$APPS/social-linker/requirements.txt"<<'R'
fastapi>=0.110
uvicorn[standard]>=0.30
neo4j>=5.21
R
cat >"$APPS/social-linker/app.py"<<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
from neo4j import GraphDatabase
import os
api=FastAPI()
NEO_URI=os.getenv("NEO4J_URI","bolt://neo4j:7687")
NEO_USER=os.getenv("NEO4J_USER","neo4j")
NEO_PASS=os.getenv("NEO4J_PASSWORD")
def drv(): return GraphDatabase.driver(NEO_URI, auth=(NEO_USER, NEO_PASS))
@api.get("/health")
def health():
    try:
        with drv() as d: d.verify_connectivity()
        return {"status":"ok"}
    except Exception as e: return {"status":"bad","error":str(e)}
class Account(BaseModel): platform:str; handle:str; name:str|None=None; person_id:str|None=None
class LinkReq(BaseModel): accounts:list[Account]
@api.post("/link_accounts")
def link_accounts(inp:LinkReq):
    q="""
    UNWIND $accs AS a
    MERGE (ac:Account {platform:a.platform, handle:a.handle})
    SET ac.name = coalesce(a.name, ac.name)
    FOREACH (_ IN CASE WHEN a.person_id IS NOT NULL THEN [1] ELSE [] END |
      MERGE (p:Person {id:a.person_id}) MERGE (p)-[:USES]->(ac)
    )
    RETURN count(ac) AS accounts"""
    with drv() as d, d.session() as s:
        res=s.run(q, accs=[a.dict() for a in inp.accounts]).single()
        return {"linked": res["accounts"]}
PY
cat >"$APPS/social-linker/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
D
sanitize "$APPS/social-linker/Dockerfile"

# ===== compose (إضافة ثلاث خدمات) =====
APPSY="$STACK/docker-compose.apps.social.yml"
cat >"$APPSY"<<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }

services:
  social-archive:
    build: { context: ../apps/social-archive, dockerfile: Dockerfile }
    container_name: ffactory_social_archive
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8084:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s; timeout: 5s; retries: 30

  video-metadata:
    build: { context: ../apps/video-metadata, dockerfile: Dockerfile }
    container_name: ffactory_video_meta
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8085:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s; timeout: 5s; retries: 30

  social-linker:
    build: { context: ../apps/social-linker, dockerfile: Dockerfile }
    container_name: ffactory_social_linker
    env_file: [ ../.env ]
    environment:
      - NEO4J_URI=bolt://neo4j:7687
      - NEO4J_USER=$${NEO4J_USER}
      - NEO4J_PASSWORD=$${NEO4J_PASSWORD}
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8087:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s; timeout: 5s; retries: 30
YML

log "build+up social pack"
docker compose --env-file "$ENV" -f "$APPSY" up -d --build
log "endpoints:"
echo "Archive:  http://127.0.0.1:8084/health"
echo "Video:    http://127.0.0.1:8085/health"
echo "Linker:   http://127.0.0.1:8087/health"
