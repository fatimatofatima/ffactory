from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from dateutil import parser as dtp
from typing import List
import math, numpy as np

api=FastAPI(title="mobility-analytics")

class Point(BaseModel):
    ts:str
    lat:float
    lon:float

class Req(BaseModel):
    points:List[Point]
    radius_m:float|None=200.0
    min_stay_min:int|None=20

def hav(a,b):
    R=6371000.0
    la1,lo1,la2,lo2=map(math.radians,(a[0],a[1],b[0],b[1]))
    dla=la2-la1; dlo=lo2-lo1
    h=math.sin(dla/2)**2 + math.cos(la1)*math.cos(la2)*math.sin(dlo/2)**2
    return 2*R*math.asin(math.sqrt(h))

@api.get("/health")
def health(): return {"status":"ok"}

@api.post("/timeline")
def timeline(r:Req):
    if not r.points: raise HTTPException(400,"empty")
    pts=sorted(r.points, key=lambda x: x.ts)
    rad=r.radius_m or 200.0
    minstay=(r.min_stay_min or 20)*60
    stays=[]
    i=0
    while i<len(pts):
        j=i
        while j+1<len(pts) and hav((pts[i].lat,pts[i].lon),(pts[j+1].lat,pts[j+1].lon))<=rad:
            j+=1
        t0=dtp.parse(pts[i].ts).timestamp(); t1=dtp.parse(pts[j].ts).timestamp()
        if t1-t0>=minstay:
            la=np.mean([p.lat for p in pts[i:j+1]])
            lo=np.mean([p.lon for p in pts[i:j+1]])
            stays.append({"start":pts[i].ts,"end":pts[j].ts,"lat":float(la),"lon":float(lo),"duration_s":int(t1-t0)})
        i=max(i+1,j+1)
    # أعلى أماكن إقامة
    top=sorted(stays,key=lambda s:s["duration_s"], reverse=True)[:5]
    # رحلات بين الإقامات
    trips=[]
    for a,b in zip(stays,stays[1:]):
        dist=hav((a["lat"],a["lon"]),(b["lat"],b["lon"]))
        trips.append({"from":[a["lat"],a["lon"]],"to":[b["lat"],b["lon"]],"dist_m":int(dist),"gap_s":int(dtp.parse(b["start"]).timestamp()-dtp.parse(a["end"]).timestamp())})
    return {"stays":stays,"top_stays":top,"trips":trips}
