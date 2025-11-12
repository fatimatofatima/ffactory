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
