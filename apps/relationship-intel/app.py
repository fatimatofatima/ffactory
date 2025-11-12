from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, psycopg, numpy as np
from datetime import datetime, timedelta
from neo4j import GraphDatabase

api=FastAPI(title="relationship-intel")

DB=os.getenv("DB_NAME","ffactory")
U=os.getenv("DB_USER","ffadmin")
P=os.getenv("DB_PASSWORD")
H=os.getenv("DB_HOST","db")
PORT=int(os.getenv("DB_PORT","5432"))

NEO_URI=os.getenv("NEO4J_URI","bolt://neo4j:7687")
NEO_USER=os.getenv("NEO4J_USER","neo4j")
NEO_PASS=os.getenv("NEO4J_PASSWORD")

def pg(): return psycopg.connect(host=H, port=PORT, dbname=DB, user=U, password=P)
def neo(): return GraphDatabase.driver(NEO_URI, auth=(NEO_USER, NEO_PASS))

DDL = """
CREATE TABLE IF NOT EXISTS people(
  id TEXT PRIMARY KEY, name TEXT, phone TEXT, home_lat DOUBLE PRECISION, home_lon DOUBLE PRECISION, work_lat DOUBLE PRECISION, work_lon DOUBLE PRECISION
);
CREATE TABLE IF NOT EXISTS places(
  id TEXT PRIMARY KEY, type TEXT, name TEXT, lat DOUBLE PRECISION, lon DOUBLE PRECISION
);
CREATE TABLE IF NOT EXISTS hotel_stays(
  id TEXT PRIMARY KEY, person_id TEXT REFERENCES people(id), place_id TEXT REFERENCES places(id),
  checkin_ts TIMESTAMPTZ, checkout_ts TIMESTAMPTZ, booking_ref TEXT, paid_cash BOOLEAN, card_last4 TEXT
);
CREATE TABLE IF NOT EXISTS device_pings(
  person_id TEXT REFERENCES people(id), device_id TEXT, ts TIMESTAMPTZ, lat DOUBLE PRECISION, lon DOUBLE PRECISION
);
CREATE TABLE IF NOT EXISTS transactions(
  id TEXT PRIMARY KEY, person_id TEXT REFERENCES people(id), ts TIMESTAMPTZ, amount NUMERIC, method TEXT, merchant_type TEXT, lat DOUBLE PRECISION, lon DOUBLE PRECISION
);
CREATE TABLE IF NOT EXISTS calls(
  caller_id TEXT, callee_id TEXT, ts TIMESTAMPTZ, duration_s INT
);
CREATE INDEX IF NOT EXISTS idx_hotel_person_ts ON hotel_stays(person_id,checkin_ts,checkout_ts);
CREATE INDEX IF NOT EXISTS idx_ping_person_ts ON device_pings(person_id,ts);
CREATE INDEX IF NOT EXISTS idx_tx_person_ts ON transactions(person_id,ts);
CREATE INDEX IF NOT EXISTS idx_calls_ts ON calls(ts);
"""

@api.on_event("startup")
def boot():
    with pg() as c: c.execute(DDL)

@api.get("/health")
def health():
    try:
        with pg() as c: c.execute("SELECT 1")
        with neo() as d: d.verify_connectivity()
        return {"status":"ok"}
    except Exception as e:
        return {"status":"bad","error":str(e)}

class PairQ(BaseModel):
    a:str; b:str
    days:int|None=90
    max_dist_m:int|None=150

def _overlap(a1,a2,b1,b2):
    s=max(a1,b1); e=min(a2,b2); return max(0,(e-s).total_seconds())

def _haversine(lat1,lon1,lat2,lon2):
    import math
    R=6371000.0
    p1,p2=math.radians(lat1),math.radians(lat2)
    dphi=math.radians(lat2-lat1); dl=math.radians(lon2-lon1)
    a=math.sin(dphi/2)**2+math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*R*math.asin(math.sqrt(a))

@api.post("/score/affair")
def score_affair(q:PairQ):
    try:
        days=q.days or 90; end=datetime.utcnow(); start=end-timedelta(days=days)
        md=q.max_dist_m or 150

        with pg() as c:
            # 1) تداخل فندقي ليلي
            rows=c.execute("""
            SELECT a.checkin_ts,a.checkout_ts,b.checkin_ts,b.checkout_ts,
                   (a.paid_cash::int + b.paid_cash::int) AS cash_pair,
                   (a.card_last4 IS NOT NULL AND a.card_last4=b.card_last4) as same_card
            FROM hotel_stays a JOIN hotel_stays b ON a.place_id=b.place_id AND a.person_id=%s AND b.person_id=%s
            WHERE a.checkin_ts<@ tstzrange(%s,%s) OR a.checkout_ts<@ tstzrange(%s,%s)
            """,(q.a,q.b,start,end,start,end)).fetchall()
        hotel_overlaps=0; same_card_count=0; cash_pairs=0
        for r in rows:
            ov=_overlap(r[0],r[1],r[2],r[3])
            if ov>=1800: hotel_overlaps+=1
            if r[5]: same_card_count+=1
            if r[4]>=1: cash_pairs+=1

        # 2) تواجد ليلي مشترك بالأجهزة
        with pg() as c:
            pa=c.execute("SELECT ts,lat,lon FROM device_pings WHERE person_id=%s AND ts BETWEEN %s AND %s",(q.a,start,end)).fetchall()
            pb=c.execute("SELECT ts,lat,lon FROM device_pings WHERE person_id=%s AND ts BETWEEN %s AND %s",(q.b,start,end)).fetchall()
        night_hits=0
        if pa and pb:
            # عينات كل 10 دقائق
            from collections import defaultdict
            def bucket(rs):
                d=defaultdict(list)
                for t,la,lo in rs:
                    if 20<=t.hour or t.hour<6:
                        k=t.replace(minute=(t.minute//10)*10,second=0,microsecond=0)
                        d[k].append((la,lo))
                return d
            A,B=bucket(pa),bucket(pb)
            keys=set(A.keys())&set(B.keys())
            for k in keys:
                for la,lo in A[k]:
                    for lb,lblo in B[k]:
                        if _haversine(la,lo,lb,lblo)<=md:
                            night_hits+=1; break

        # 3) صمت متزامن للأجهزة أثناء التداخل الفندقي
        silent_overlap=0
        if rows:
            with pg() as c:
                for r in rows:
                    t1=r[0]; t2=r[1]
                    a_ct=c.execute("SELECT count(*) FROM device_pings WHERE person_id=%s AND ts BETWEEN %s AND %s",(q.a,t1,t2)).fetchone()[0]
                    b_ct=c.execute("SELECT count(*) FROM device_pings WHERE person_id=%s AND ts BETWEEN %s AND %s",(q.b,t1,t2)).fetchone()[0]
                    if a_ct<=1 and b_ct<=1: silent_overlap+=1

        # 4) مكالمات بين الطرفين قبل/بعد الإقامات مباشرة
        with pg() as c:
            calls=c.execute("""
            SELECT count(*) FROM calls
            WHERE ((caller_id=%s AND callee_id=%s) OR (caller_id=%s AND callee_id=%s))
              AND ts BETWEEN %s AND %s
            """,(q.a,q.b,q.b,q.a,start,end)).fetchone()[0]

        # تجميع نقاط
        score = (hotel_overlaps*3) + (night_hits*0.5) + (silent_overlap*2) + (same_card_count*2) + (cash_pairs*1) + (calls*0.2)
        return {
            "a":q.a,"b":q.b,"window_days":days,"max_dist_m":md,
            "features":{"hotel_overlaps":hotel_overlaps,"same_card_pairs":same_card_count,"cash_pairs":cash_pairs,
                        "night_colocations":night_hits,"silent_overlap":silent_overlap,"calls_between":calls},
            "score": float(score)
        }
    except Exception as e:
        raise HTTPException(500,str(e))

class IdQ(BaseModel):
    id:str; days:int|None=90

@api.post("/places/safehouses")
def safehouses(q:IdQ):
    days=q.days or 90; end=datetime.utcnow(); start=end-timedelta(days=days)
    try:
        with pg() as c:
            # أماكن ليلية متكررة ليست بيت أو عمل
            rows=c.execute("""
            WITH nightly AS (
              SELECT date_trunc('hour',ts) h, lat, lon
              FROM device_pings WHERE person_id=%s AND ts BETWEEN %s AND %s AND (extract(hour from ts)>=20 OR extract(hour from ts)<6)
            )
            SELECT round(avg(lat)::numeric,6) AS lat, round(avg(lon)::numeric,6) AS lon, count(*) AS hits
            FROM nightly GROUP BY round(lat::numeric,3), round(lon::numeric,3) HAVING count(*)>=6 ORDER BY hits DESC LIMIT 20
            """,(q.id,start,end)).fetchall()
        return {"id":q.id,"candidates":[{"lat":float(r[0]),"lon":float(r[1]),"hits":int(r[2])} for r in rows]}
    except Exception as e:
        raise HTTPException(500,str(e))

@api.get("/graph/bootstrap")
def graph_bootstrap():
    try:
        with neo() as d, d.session() as s:
            s.run("CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE")
            s.run("CREATE CONSTRAINT place_id IF NOT EXISTS FOR (pl:Place) REQUIRE pl.id IS UNIQUE")
        return {"ok":True}
    except Exception as e:
        raise HTTPException(500,str(e))

class Seed(BaseModel):
    id:str; k:int|None=10

@api.post("/graph/link_candidates")
def link_candidates(seed:Seed):
    try:
        with neo() as d, d.session() as s:
            q="""
            MATCH (a:Person {id:$id})-[:STAYED_AT]->(h:Place)<-[:STAYED_AT]-(b:Person)
            WITH b, count(*) AS co_stays
            OPTIONAL MATCH (a)-[:CALLED]-(b)
            WITH b, co_stays, count(*) AS calls
            RETURN b.id AS id, co_stays, calls
            ORDER BY co_stays DESC, calls DESC LIMIT $k
            """
            out=list(s.run(q, id=seed.id, k=seed.k or 10))
        return {"seed":seed.id,"candidates":[{"id":r["id"],"co_stays":r["co_stays"],"calls":r["calls"]} for r in out]}
    except Exception as e:
        raise HTTPException(500,str(e))
