import os, time, psycopg2
from neo4j import GraphDatabase

DB_URL=os.getenv("DB_URL","postgresql://forensic_user:STRONG_PASS@db:5432/forensic_db")
NEO4J_URI=os.getenv("NEO4J_URI","bolt://neo4j:7687")
NEO4J_AUTH=os.getenv("NEO4J_AUTH","none")
auth=None if NEO4J_AUTH.lower()=="none" else tuple(NEO4J_AUTH.split(":",1))

def ready():
    psycopg2.connect(DB_URL, connect_timeout=5).close()
    drv=GraphDatabase.driver(NEO4J_URI, auth=auth); drv.verify_connectivity(); drv.close()

if __name__=="__main__":
    while True:
        try: ready(); print("ready"); 
        except Exception as e: print("not-ready:", e)
        time.sleep(5)
