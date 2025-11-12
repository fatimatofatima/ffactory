from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from dateutil import parser as dtp
import numpy as np, math
from typing import List, Optional, Dict

api=FastAPI(title="behavioral-analytics")

class Event(BaseModel):
    ts: str               # ISO datetime
    actor: str            # معرّف الشخص
    type: str             # نوع الحدث: call,msg,txn,checkin,post,...
    loc: Optional[str]=None

class Req(BaseModel):
    events: List[Event]

def _hour(ts): return dtp.parse(ts).hour
def _secs(ts): return dtp.parse(ts).timestamp()

@api.get("/health")
def health(): return {"status":"ok"}

@api.post("/profile")
def profile(r: Req):
    if not r.events: raise HTTPException(400, "empty")
    ev=sorted(r.events, key=lambda e: e.ts)
    # توزيع الساعات
    hrs=[_hour(e.ts) for e in ev]
    hist=np.bincount(hrs, minlength=24).astype(float)
    p=hist/hist.sum()
    ent=-np.sum([x*math.log(x) for x in p if x>0.0])
    routine=1.0 - ent/math.log(24.0)
    night_ratio=float(hist[0:6].sum()+hist[22:24].sum())/float(hist.sum())
    # انفجارية التوقيت
    t=np.array([_secs(e.ts) for e in ev], dtype=float)
    dt=np.diff(t)
    if len(dt)>=2:
        mu=float(dt.mean()); sd=float(dt.std())
        burst=(sd-mu)/(sd+mu) if (sd+mu)>0 else 0.0
    else:
        burst=0.0
    # تنوع الأنواع والمواقع
    types={}
    locs={}
    for e in ev:
        types[e.type]=types.get(e.type,0)+1
        if e.loc: locs[e.loc]=locs.get(e.loc,0)+1
    type_diversity=len(types)
    loc_diversity=len(locs)
    # درجة السرية الأولية
    private_flags=sum(1 for e in ev if e.type in ("dm","secret_chat","hidden_txn"))
    secrecy_score=min(1.0, 0.2*private_flags + 0.5*night_ratio + 0.3*burst)
    # خطر تعدد العلاقات (مؤشر أولي من التنوع الزمني + السرية)
    multi_rel_risk=min(1.0, 0.6*secrecy_score + 0.4*(1.0-routine))
    return {
        "counts":{"total":len(ev)},
        "time":{"hist":hist.tolist(),"night_ratio":night_ratio,"routine":routine,"burstiness":burst},
        "diversity":{"types":type_diversity,"locations":loc_diversity},
        "scores":{"secrecy":secrecy_score,"multi_relationship_risk":multi_rel_risk}
    }
