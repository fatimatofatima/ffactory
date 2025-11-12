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
