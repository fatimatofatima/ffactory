from fastapi import FastAPI
import json, os

app = FastAPI(title="quantum-security")

@app.get("/health")
def health():
    try:
        p = "/app/keys/quantum_keys.json"
        data = json.load(open(p)) if os.path.exists(p) else {}
        return {"status":"ok","keys":bool(data)}
    except Exception as e:
        return {"status":"err","error":str(e)}
