from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Dict
import os

api=FastAPI(title="FFactory NER")

CANDIDATES=[
    "CAMeL-Lab/bert-base-arabic-camelbert-msa",
    "asafaya/bert-base-arabic-ner",
    "Davlan/xlm-roberta-base-ner-hrl",
    "dslim/bert-base-NER"
]
MODEL=os.getenv("NER_MODEL") or None
ERR=None
nlp=None

def load():
    global nlp, MODEL, ERR
    from transformers import pipeline
    errs=[]
    if MODEL: order=[MODEL]+[m for m in CANDIDATES if m!=MODEL]
    else: order=CANDIDATES
    for m in order:
        try:
            nlp=pipeline("token-classification", model=m, aggregation_strategy="simple")
            MODEL=m; ERR=None; return
        except Exception as e:
            errs.append(f"{m}: {e}")
    ERR=" | ".join(errs)

load()

class Inp(BaseModel): text:str

@api.get("/health")
def health(): return {"ready": nlp is not None, "model": MODEL, "error": ERR}

MAP={"B-PER":"PERSON", "I-PER":"PERSON", "PER":"PERSON",
     "B-ORG":"ORG","I-ORG":"ORG","ORG":"ORG",
     "B-LOC":"LOC","I-LOC":"LOC","LOC":"LOC"}

@api.post("/ner")
def ner(inp: Inp):
    if nlp is None: return {"error": ERR or "model not ready"}
    raw=nlp(inp.text)
    ents=[]
    for e in raw:
        label=MAP.get(e["entity_group"], e["entity_group"])
        ents.append({"text":e["word"],"type":label,"score":float(e["score"]), "start": int(e.get("start", -1)), "end": int(e.get("end", -1))})
    return {"entities": ents}
