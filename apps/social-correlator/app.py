from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, re, psycopg
from dateutil import parser as dtp
from rapidfuzz import fuzz
import phonenumbers
from neo4j import GraphDatabase

api=FastAPI(title="social-correlator")

# Postgres
DBH=os.getenv("DB_HOST","db"); DBPORT=int(os.getenv("DB_PORT","5432"))
DBN=os.getenv("POSTGRES_DB","ffactory"); DBU=os.getenv("POSTGRES_USER","ffadmin"); DBPW=os.getenv("POSTGRES_PASSWORD")
def db(): return psycopg.connect(host=DBH, port=DBPORT, dbname=DBN, user=DBU, password=DBPW)

# Neo4j
NEO_URI=os.getenv("NEO4J_URI","bolt://neo4j:7687"); NEO_USER=os.getenv("NEO4J_USER","neo4j"); NEO_PASS=os.getenv("NEO4J_PASSWORD")
def bolt(): return GraphDatabase.driver(NEO_URI, auth=(NEO_USER, NEO_PASS))

HANDLE_RX=re.compile(r"^@?([A-Za-z0-9._-]{3,})$")
EMAIL_RX=re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PHONE_RX=re.compile(r"\+?\d[\d\s().-]{6,}")

def norm_handle(s:str|None):
    if not s: return None
    m=HANDLE_RX.match(s.strip()); 
    return m.group(1).lower() if m else None

def norm_email(s:str): return s.strip().lower()

def norm_phone(s:str):
    s=s.strip()
    try:
        p=phonenumbers.parse(s, None)
        if phonenumbers.is_possible_number(p) and phonenumbers.is_valid_number(p):
            return phonenumbers.format_number(p, phonenumbers.PhoneNumberFormat.E164)
    except: pass
    return None

def ensure_schema():
    with db() as c, c.cursor() as cur:
        cur.execute("""
        CREATE TABLE IF NOT EXISTS sm_accounts(
          id BIGSERIAL PRIMARY KEY,
          platform TEXT, handle TEXT, name TEXT, external_id TEXT,
          email TEXT, phone TEXT,
          extra JSONB,
          UNIQUE(platform, COALESCE(handle,''), COALESCE(external_id,''))
        );
        """)
        c.commit()

def upsert_account(cur, platform, handle, name, external_id, email, phone, extra):
    cur.execute("""
      INSERT INTO sm_accounts(platform,handle,name,external_id,email,phone,extra)
      VALUES(%s,%s,%s,%s,%s,%s,%s)
      ON CONFLICT (platform, COALESCE(handle,''), COALESCE(external_id,''))
      DO UPDATE SET name=COALESCE(EXCLUDED.name, sm_accounts.name),
                    email=COALESCE(EXCLUDED.email, sm_accounts.email),
                    phone=COALESCE(EXCLUDED.phone, sm_accounts.phone)
      RETURNING id
    """,(platform, handle, name, external_id, email, phone, extra))
    return cur.fetchone()[0]

def build_accounts_from_messages(limit:int|None=None):
    ensure_schema()
    with db() as c, c.cursor() as cur:
        q="SELECT platform, author, peer, text, ts FROM sm_messages"
        if limit: q+= " ORDER BY ts DESC NULLS LAST LIMIT %s"
        cur.execute(q, (limit,) if limit else None)
        rows=cur.fetchall()
        for platform, author, peer, text, ts in rows:
            # author
            h=norm_handle(author); name=(author if not h else None)
            email=None; phone=None
            if text:
                em=EMAIL_RX.findall(text); ph=PHONE_RX.findall(text)
                email=norm_email(em[0]) if em else None
                phone=norm_phone(ph[0]) if ph else None
            upsert_account(cur, platform, h, name, None, email, phone, {"src":"messages"})
            # peer كمحاور
            if peer:
                hp=norm_handle(peer); namep=(peer if not hp else None)
                upsert_account(cur, platform, hp, namep, None, None, None, {"src":"peer"})
        c.commit()

def neo_bootstrap():
    with bolt() as d, d.session() as s:
        s.run("CREATE CONSTRAINT account_key IF NOT EXISTS FOR (a:Account) REQUIRE (a.platform,a.handle) IS UNIQUE;")
        s.run("CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;")

def push_accounts_to_graph():
    with db() as c, c.cursor() as cur:
        cur.execute("SELECT id,platform,handle,name,email,phone FROM sm_accounts")
        acc=cur.fetchall()
    with bolt() as d, d.session() as s:
        s.run("""
        UNWIND $rows AS r
        MERGE (a:Account {platform:r.platform, handle:coalesce(r.handle,'nohandle:'+toString(r.id))})
        SET a.name=coalesce(r.name,a.name), a.email=coalesce(r.email,a.email), a.phone=coalesce(r.phone,a.phone)
        """, rows=[{"id":i,"platform":p,"handle":h,"name":n,"email":e,"phone":ph} for (i,p,h,n,e,ph) in acc])

def link_rules():
    # قاعدة 1: نفس الهاتف → ALIAS_OF وزن 1.0
    with db() as c, c.cursor() as cur:
        cur.execute("""SELECT phone, array_agg(json_build_object('platform',platform,'handle',handle,'id',id,'name',name)) 
                       FROM sm_accounts WHERE phone IS NOT NULL GROUP BY phone HAVING count(*)>1""")
        same_phone=cur.fetchall()
    # قاعدة 2: نفس البريد → ALIAS_OF وزن 0.95
        cur.execute("""SELECT email, array_agg(json_build_object('platform',platform,'handle',handle,'id',id,'name',name)) 
                       FROM sm_accounts WHERE email IS NOT NULL GROUP BY email HAVING count(*)>1""")
        same_email=cur.fetchall()
    # قاعدة 3: نفس الـ handle عبر منصتين + تشابه اسم ≥ 90 → ALIAS_OF وزن 0.8
        cur.execute("""SELECT handle, array_agg(json_build_object('platform',platform,'handle',handle,'id',id,'name',name))
                       FROM sm_accounts WHERE handle IS NOT NULL GROUP BY handle HAVING count(*)>1""")
        same_handle=cur.fetchall()
    # دفع للـ graph
    with bolt() as d, d.session() as s:
        # هاتف
        for phone, arr in same_phone:
            a=list(arr)
            for i in range(len(a)):
                for j in range(i+1,len(a)):
                    s.run("""
                    MATCH (x:Account {platform:$p1, handle:$h1}), (y:Account {platform:$p2, handle:$h2})
                    MERGE (x)-[r:ALIAS_OF]->(y)
                    SET r.weight=1.0, r.reason='phone', r.phone=$phone
                    """, p1=a[i]['platform'], h1=a[i]['handle'], p2=a[j]['platform'], h2=a[j]['handle'], phone=phone)
        # بريد
        for email, arr in same_email:
            a=list(arr)
            for i in range(len(a)):
                for j in range(i+1,len(a)):
                    s.run("""
                    MATCH (x:Account {platform:$p1, handle:$h1}), (y:Account {platform:$p2, handle:$h2})
                    MERGE (x)-[r:ALIAS_OF]->(y)
                    SET r.weight=0.95, r.reason='email', r.email=$email
                    """, p1=a[i]['platform'], h1=a[i]['handle'], p2=a[j]['platform'], h2=a[j]['handle'], email=email)
        # Handle + تشابه الاسم
        for handle, arr in same_handle:
            a=list(arr)
            for i in range(len(a)):
                for j in range(i+1,len(a)):
                    n1=a[i].get('name') or ''
                    n2=a[j].get('name') or ''
                    sim=fuzz.WRatio(n1, n2) if n1 and n2 else 0
                    if a[i]['platform']!=a[j]['platform'] and sim>=90:
                        s.run("""
                        MATCH (x:Account {platform:$p1, handle:$h}), (y:Account {platform:$p2, handle:$h})
                        MERGE (x)-[r:ALIAS_OF]->(y)
                        SET r.weight=0.8, r.reason='handle+name', r.name_sim=$sim
                        """, p1=a[i]['platform'], p2=a[j]['platform'], h=handle, sim=float(sim))
    return {"linked_phone":len(same_phone), "linked_email":len(same_email), "linked_handle_groups":len(same_handle)}

def build_contact_edges(limit:int|None=None):
    # تحويل الرسائل إلى CONTACTED(count, first_ts, last_ts)
    with db() as c, c.cursor() as cur:
        q="SELECT platform, author, peer, ts FROM sm_messages WHERE author IS NOT NULL AND peer IS NOT NULL"
        if limit: q+=" ORDER BY ts DESC NULLS LAST LIMIT %s"
        cur.execute(q, (limit,) if limit else None)
        rows=cur.fetchall()
    agg={}
    for platform, author, peer, ts in rows:
        h1=norm_handle(author) or f"name:{author}"
        h2=norm_handle(peer) or f"name:{peer}"
        key=(platform,h1,h2)
        d=agg.get(key, {"count":0, "first":ts, "last":ts})
        d["count"]+=1
        d["first"]=min(d["first"], ts) if d["first"] and ts else d["first"] or ts
        d["last"]=max(d["last"], ts) if d["last"] and ts else d["last"] or ts
        agg[key]=d
    with bolt() as d, d.session() as s:
        for (platform,h1,h2),meta in agg.items():
            # نستخدم handle إن وجد وإلا نضع وسم name:
            handle1=h1 if not h1.startswith("name:") else None
            name1=h1[5:] if h1 and h1.startswith("name:") else None
            handle2=h2 if not h2.startswith("name:") else None
            name2=h2[5:] if h2 and h2.startswith("name:") else None
            s.run("""
            MERGE (a:Account {platform:$p, handle:coalesce($h1, 'nohandle:'+toString(id(a)))})
            ON CREATE SET a.name=$n1
            MERGE (b:Account {platform:$p, handle:coalesce($h2, 'nohandle:'+toString(id(b)))})
            ON CREATE SET b.name=$n2
            MERGE (a)-[r:CONTACTED]->(b)
            SET r.count=coalesce(r.count,0)+$c, r.first_ts=coalesce(r.first_ts,$f), r.last_ts=CASE WHEN r.last_ts IS NULL OR $l>r.last_ts THEN $l ELSE r.last_ts END
            """, p=platform, h1=handle1, n1=name1, h2=handle2, n2=name2, c=meta["count"], f=meta["first"], l=meta["last"])
    return {"pairs":len(agg)}

class RunReq(BaseModel):
    limit:int|None=None
    push_only:bool|None=False

@api.get("/health")
def health():
    try:
        with db() as c: c.execute("SELECT 1;")
        with bolt() as d: d.verify_connectivity()
        return {"status":"ok"}
    except Exception as e:
        return {"status":"bad","error":str(e)}

@api.post("/bootstrap")
def bootstrap():
    ensure_schema(); neo_bootstrap()
    return {"ok":True}

@api.post("/build")
def build(req:RunReq):
    build_accounts_from_messages(req.limit)
    neo_bootstrap()
    push_accounts_to_graph()
    if not req.push_only:
        link_rules()
        build_contact_edges(req.limit)
    return {"done":True}
