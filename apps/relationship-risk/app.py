from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from dateutil import parser as dtp
from typing import List, Optional
import math, numpy as np
api=FastAPI(title="relationship-risk")

class Edge(BaseModel):
    ts:str           # وقت التفاعل
    a:str            # طرف أول
    b:str            # طرف ثانٍ
    channel:str      # sms,call,dm,meet,txn
    privacy:Optional[bool]=None  # خاص/علني

class Req(BaseModel):
    edges:List[Edge]

@api.get("/health")
def h(): return {"status":"ok"}

@api.post("/score")
def score(r:Req):
    if not r.edges: raise HTTPException(400,"empty")
    # وزن زمني متناقص
    now=max(dtp.parse(e.ts).timestamp() for e in r.edges)
    def w(ts): 
        d=max(0.0, now-dtp.parse(ts).timestamp())
        half=30*24*3600.0
        return 0.5**(d/half)
    # مجاميع لكل زوج
    S={}
    for e in r.edges:
        key=tuple(sorted((e.a,e.b)))
        s=S.get(key, {"w":0.0,"priv":0,"night":0,"meet":0,"cnt":0})
        s["w"]+=w(e.ts)
        s["cnt"]+=1
        if e.privacy: s["priv"]+=1
        hr=dtp.parse(e.ts).hour
        if hr<6 or hr>=22: s["night"]+=1
        if e.channel in ("meet","txn"): s["meet"]+=1
        S[key]=s
    results=[]
    for (a,b),v in S.items():
        base=min(1.0, v["w"])
        secrecy = (v["priv"]/max(1,v["cnt"]))*0.5 + (v["night"]/max(1,v["cnt"]))*0.5
        intimacy = min(1.0, 0.6*base + 0.4*(v["meet"]/max(1,v["cnt"])))
        risk = min(1.0, 0.5*secrecy + 0.5*intimacy)
        results.append({"pair":[a,b],"intimacy":float(intimacy),"secrecy":float(secrecy),"risk":float(risk),"counts":v})
    results.sort(key=lambda x:x["risk"], reverse=True)
    return {"pairs":results[:50]}
