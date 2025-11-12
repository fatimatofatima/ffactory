from fastapi import FastAPI, Query
import os, time
import psycopg
from neo4j import GraphDatabase

api=FastAPI(title="FFactory Correlation")

DB=os.getenv("DB_NAME","ffactory")
DBU=os.getenv("DB_USER","ffadmin")
DBP=os.getenv("DB_PASSWORD")
DBH=os.getenv("DB_HOST","db")
DBPORT=int(os.getenv("DB_PORT","5432"))
NEO_URI=os.getenv("NEO4J_URI","bolt://neo4j:7687")
NEO_USER=os.getenv("NEO4J_USER","neo4j")
NEO_PASS=os.getenv("NEO4J_PASSWORD")

def pg():
    return psycopg.connect(host=DBH, port=DBPORT, dbname=DB, user=DBU, password=DBP)

def bolt():
    return GraphDatabase.driver(NEO_URI, auth=(NEO_USER, NEO_PASS))

@api.get("/health")
def health():
    try:
        with pg() as c: c.execute("SELECT 1;").fetchone()
        with bolt() as d: d.verify_connectivity()
        return {"status":"ok"}
    except Exception as e:
        return {"status":"bad","error":str(e)}

@api.post("/bootstrap")
def bootstrap():
    # جداول بسيطة إن لم تكن موجودة
    with pg() as c, c.cursor() as cur:
        cur.execute("""CREATE TABLE IF NOT EXISTS people (id UUID DEFAULT gen_random_uuid() PRIMARY KEY, name TEXT, updated_at TIMESTAMP DEFAULT NOW());""")
        cur.execute("""CREATE TABLE IF NOT EXISTS files  (id UUID DEFAULT gen_random_uuid() PRIMARY KEY, path TEXT, sha256 TEXT, updated_at TIMESTAMP DEFAULT NOW());""")
        cur.execute("""CREATE TABLE IF NOT EXISTS events (id UUID DEFAULT gen_random_uuid() PRIMARY KEY, title TEXT, ts TIMESTAMP DEFAULT NOW(), updated_at TIMESTAMP DEFAULT NOW());""")
        cur.execute("""CREATE TABLE IF NOT EXISTS links  (src UUID, dst UUID, type TEXT, weight FLOAT DEFAULT 1.0, updated_at TIMESTAMP DEFAULT NOW());""")
        c.commit()
    with bolt() as drv, drv.session() as s:
        s.run("CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;")
        s.run("CREATE CONSTRAINT file_id IF NOT EXISTS FOR (f:File) REQUIRE f.id IS UNIQUE;")
        s.run("CREATE CONSTRAINT event_id IF NOT EXISTS FOR (e:Event) REQUIRE e.id IS UNIQUE;")
    return {"ok":True}

def _load(rows, label, key="id", setmap=None, session=None):
    session.run(f"UNWIND $b AS r MERGE (n:{label} {{id:r.{key}}}) SET n+=r", b=rows)

@api.post("/etl/full")
def etl_full():
    with pg() as c:
        P=c.execute("SELECT id::text, name FROM people").fetchall()
        F=c.execute("SELECT id::text, path, sha256 FROM files").fetchall()
        E=c.execute("SELECT id::text, title, EXTRACT(EPOCH FROM ts) AS ts FROM events").fetchall()
        L=c.execute("SELECT src::text, dst::text, type, weight FROM links").fetchall()
    with bolt() as drv, drv.session() as s:
        _load([{"id":p[0],"name":p[1]} for p in P], "Person", session=s)
        _load([{"id":f[0],"path":f[1],"sha256":f[2]} for f in F], "File", session=s)
        _load([{"id":e[0],"title":e[1],"ts":e[2]} for e in E], "Event", session=s)
        s.run("""UNWIND $b AS r
                 MATCH (a {id:r.src}), (b {id:r.dst})
                 MERGE (a)-[x:REL {type:r.type}]->(b)
                 SET x.weight = coalesce(x.weight,0)+r.weight""", b=[{"src":l[0],"dst":l[1],"type":l[2],"weight":l[3]} for l in L])
    return {"nodes": len(P)+len(F)+len(E), "rels": len(L)}

@api.post("/etl/incremental")
def etl_inc(since: str = Query(..., description="ISO timestamp")):
    with pg() as c:
        P=c.execute("SELECT id::text, name FROM people WHERE updated_at >= %s", (since,)).fetchall()
        F=c.execute("SELECT id::text, path, sha256 FROM files WHERE updated_at >= %s", (since,)).fetchall()
        E=c.execute("SELECT id::text, title, EXTRACT(EPOCH FROM ts) AS ts FROM events WHERE updated_at >= %s", (since,)).fetchall()
        L=c.execute("SELECT src::text, dst::text, type, weight FROM links WHERE updated_at >= %s", (since,)).fetchall()
    with bolt() as drv, drv.session() as s:
        if P: _load([{"id":p[0],"name":p[1]} for p in P], "Person", session=s)
        if F: _load([{"id":f[0],"path":f[1],"sha256":f[2]} for f in F], "File", session=s)
        if E: _load([{"id":e[0],"title":e[1],"ts":e[2]} for e in E], "Event", session=s)
        if L:
            s.run("""UNWIND $b AS r
                     MATCH (a {id:r.src}), (b {id:r.dst})
                     MERGE (a)-[x:REL {type:r.type}]->(b)
                     SET x.weight = coalesce(x.weight,0)+r.weight""", b=[{"src":l[0],"dst":l[1],"type":l[2],"weight":l[3]} for l in L])
    return {"nodes": len(P)+len(F)+len(E), "rels": len(L)}
