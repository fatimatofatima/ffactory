from fastapi import FastAPI, Query
import os, psycopg2, json, requests

DB = os.getenv("DB_URL")
NC = os.getenv("NEURAL_CORE_URL","http://neural-core:8000")
app = FastAPI(title="ai-reporting")

@app.get("/health")
def health():
    ok_db = False
    try:
        conn = psycopg2.connect(DB); conn.close(); ok_db = True
    except: pass
    try:
        requests.get(f"{NC}/health", timeout=2).raise_for_status()
        ok_nc = True
    except:
        ok_nc = False
    return {"db":ok_db,"neural_core":ok_nc}

@app.get("/report")
def report(case_id: str = Query(...)):
    # نموذج بسيط
    return {"case_id":case_id,"summary":"stub","suggestions":["check timeline","review media"]}
