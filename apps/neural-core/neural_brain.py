from fastapi import FastAPI
from pydantic import BaseModel
import numpy as np

app = FastAPI(title="Neural Core")

class AnalyzeIn(BaseModel):
    text: str = None

@app.post("/analyze")
def analyze(input: AnalyzeIn):
    return {"risk_score": 0.15, "entities": ["TEST"]}

@app.get("/health")
def health():
    return {"status": "يعمل"}
