from fastapi import FastAPI
from pydantic import BaseModel
import os, requests

NC = os.getenv("NEURAL_CORE_URL","http://neural-core:8000")
app = FastAPI(title="social-intelligence")

class PostIn(BaseModel):
    text: str

@app.get("/health")
def health(): return {"status":"ok"}

@app.post("/analyze_post")
def analyze_post(p: PostIn):
    r = requests.post(f"{NC}/analyze", json={"text":p.text})
    out = r.json()
    return {"risk": out.get("text",{}).get("risk_score",0.0), "core": out}
