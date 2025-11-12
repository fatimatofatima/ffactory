import os, tempfile, subprocess, hashlib
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from minio import Minio
import httpx, psycopg2
from neo4j import GraphDatabase

def env(k, d=None): return os.getenv(k, d)

DB_URL           = env("DB_URL")
MINIO_URL        = env("MINIO_URL","http://minio:9000")
MINIO_ACCESS_KEY = env("MINIO_ACCESS_KEY")
MINIO_SECRET_KEY = env("MINIO_SECRET_KEY")
ASR_URL          = env("ASR_URL","http://asr-engine:8004")
NEURAL_CORE_URL  = env("NEURAL_CORE_URL","http://neural-core:8000")
NEO4J_URI        = env("NEO4J_URI","bolt://neo4j:7687")
NEO4J_AUTH       = env("NEO4J_AUTH","none")

client = Minio(MINIO_URL.replace("http://","").replace("https://",""),
               access_key=MINIO_ACCESS_KEY, secret_key=MINIO_SECRET_KEY, secure=MINIO_URL.startswith("https"))

def sha256_file(p):
    h=hashlib.sha256()
    with open(p,"rb") as f:
        for b in iter(lambda:f.read(1024*1024), b""):
            h.update(b)
    return h.hexdigest()

class IngestReq(BaseModel):
    bucket: str
    key: str
    case_id: str | None = None

app = FastAPI(title="Ingest Worker", version="1.0")

@app.get("/health")
def health(): return {"status":"healthy","service":"ingest-worker"}

@app.post("/ingest/object")
async def ingest_object(req: IngestReq):
    # 1) تنزيل من MinIO
    with tempfile.TemporaryDirectory() as td:
        local = os.path.join(td, os.path.basename(req.key))
        client.fget_object(req.bucket, req.key, local)
        size = os.path.getsize(local)
        sha = sha256_file(local)

        # 2) تحديد النوع واستخراج الصوت لو فيديو
        ext = os.path.splitext(local)[1].lower()
        media_type = "audio"
        audio_path = local
        if ext in (".mp4",".mkv",".avi",".mov",".webm"):
            media_type = "video"
            audio_path = os.path.join(td, "audio.wav")
            subprocess.run(["ffmpeg","-y","-i",local,"-vn","-ac","1","-ar","16000",audio_path],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # 3) استدعاء ASR
        text, lang = None, None
        try:
            async with httpx.AsyncClient(timeout=120) as cli:
                with open(audio_path,"rb") as f:
                    r = await cli.post(f"{ASR_URL}/transcribe", files={"file":("input.wav",f,"audio/wav")})
                data = r.json()
                text = data.get("text") or data.get("transcript")
                lang = data.get("lang") or "ar"
        except Exception:
            text = None

        # 4) تخزين media + transcript في Postgres
        with psycopg2.connect(DB_URL) as conn:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute("""INSERT INTO media_assets(case_id,bucket,object_key,media_type,size_bytes,sha256)
                               VALUES (%s,%s,%s,%s,%s,%s) RETURNING id""",
                            (req.case_id, req.bucket, req.key, media_type, size, sha))
                media_id = cur.fetchone()[0]
                transcript_id = None
                if text:
                    cur.execute("""INSERT INTO transcripts(media_id,lang,text) VALUES (%s,%s,%s) RETURNING id""",
                                (media_id, lang, text))
                    transcript_id = cur.fetchone()[0]

        # 5) استخراج كيانات عبر Neural-Core
        entities = []
        if text:
            try:
                async with httpx.AsyncClient(timeout=30) as cli:
                    r = await cli.post(f"{NEURAL_CORE_URL}/analyze", json={"text": text, "language": lang})
                    entities = r.json().get("analysis",{}).get("entities",[])
            except Exception:
                entities = []

        # 6) كتابة الكيانات وربطها
        with psycopg2.connect(DB_URL) as conn:
            conn.autocommit = True
            new_ids=[]
            with conn.cursor() as cur:
                for e in entities:
                    et = (e.get("type") or e.get("label") or "ENTITY").upper()
                    val = e.get("text") or e.get("value")
                    if not val: continue
                    cur.execute("""INSERT INTO nlp_entities(case_id,entity_type,value,source)
                                   VALUES (%s,%s,%s,%s) RETURNING id""",
                                (req.case_id, et, val, "neural-core"))
                    new_ids.append(cur.fetchone()[0])

        # 7) دفع للـ Neo4j
        auth=None
        if NEO4J_AUTH and NEO4J_AUTH.lower()!="none":
            user,pw = NEO4J_AUTH.split("/",1) if "/" in NEO4J_AUTH else NEO4J_AUTH.split("/",1)
            from neo4j import basic_auth
            auth = basic_auth(user,pw)
        driver = GraphDatabase.driver(NEO4J_URI, auth=auth)
        with driver.session() as s:
            s.run("""
            MERGE (c:Case {case_id:$case_id})
            MERGE (m:Media {sha256:$sha})
              SET m.bucket=$bucket, m.key=$key, m.type=$mtype
            MERGE (c)-[:HAS_MEDIA]->(m)
            """, case_id=req.case_id, sha=sha, bucket=req.bucket, key=req.key, mtype=media_type)
            if text:
                s.run("""
                MATCH (m:Media {sha256:$sha})
                MERGE (t:Transcript {id:$tid})
                  SET t.lang=$lang, t.text=$text
                MERGE (m)-[:HAS_TRANSCRIPT]->(t)
                """, sha=sha, tid=str(transcript_id), lang=lang, text=text)
            for e in entities:
                et = (e.get("type") or e.get("label") or "ENTITY").upper()
                val = e.get("text") or e.get("value")
                if not val: continue
                s.run("""
                MERGE (c:Case {case_id:$case_id})
                MERGE (e:%s {value:$val})
                MERGE (c)-[:MENTIONS]->(e)
                """ % et, case_id=req.case_id, val=val)

        return {
            "status":"ok",
            "case_id": req.case_id,
            "media_type": media_type,
            "size_bytes": size,
            "sha256": sha,
            "transcribed": bool(text),
            "entities_count": len(entities)
        }
