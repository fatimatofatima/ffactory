from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, hashlib, requests, sqlite3, ssdeep, csv, gzip, bz2
api=FastAPI()
DB=os.getenv("NSRL_DB_PATH","/data/hashsets/nsrl.sqlite")
os.makedirs(os.path.dirname(DB), exist_ok=True)
def db_init():
    con=sqlite3.connect(DB); cur=con.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS nsrl(sha1 TEXT PRIMARY KEY)")
    cur.execute("PRAGMA journal_mode=WAL"); con.commit(); con.close()
db_init()
class FileReq(BaseModel): file_url:str
class LoadReq(BaseModel): nsrl_url:str
@api.get("/health") 
def health(): return {"status":"ok","nsrl_db":os.path.exists(DB)}
def fetch(url)->bytes:
    r=requests.get(url, timeout=600); r.raise_for_status(); return r.content
@api.post("/hash")
def do_hash(req:FileReq):
    b=fetch(req.file_url)
    return {"md5":hashlib.md5(b).hexdigest(),"sha1":hashlib.sha1(b).hexdigest(),
            "sha256":hashlib.sha256(b).hexdigest(),"ssdeep":ssdeep.hash(b)}
@api.post("/nsrl/load")
def nsrl_load(req:LoadReq):
    raw=fetch(req.nsrl_url)
    if req.nsrl_url.endswith(".gz"): raw=gzip.decompress(raw)
    if req.nsrl_url.endswith(".bz2"): raw=bz2.decompress(raw)
    con=sqlite3.connect(DB); cur=con.cursor(); cur.execute("BEGIN")
    ins=0
    try:
        for row in csv.DictReader(io.StringIO(raw.decode(errors="ignore"))):
            sha=(row.get("SHA-1") or row.get("sha1") or row.get("SHA1") or "").strip().upper()
            if len(sha)==40:
                try: cur.execute("INSERT OR IGNORE INTO nsrl(sha1) VALUES(?)",(sha,)); ins+=1
                except Exception: pass
        con.commit()
    finally: con.close()
    return {"inserted":ins}
@api.get("/nsrl/check")
def nsrl_check(sha1:str):
    con=sqlite3.connect(DB); cur=con.execute("SELECT 1 FROM nsrl WHERE sha1=? LIMIT 1;",(sha1.upper(),))
    ok = cur.fetchone() is not None; con.close(); return {"present":ok}
