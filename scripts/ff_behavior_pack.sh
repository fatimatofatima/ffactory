#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير مُثبت"
docker compose version >/dev/null 2>&1 || die "docker compose غير مُثبت"

FF=/opt/ffactory
APPS=$FF/apps
STACK=$FF/stack
NET=ffactory_ffactory_net
ENVF=$FF/.env
YML=$STACK/docker-compose.behavior.yml

[ -f "$ENVF" ] && set -a && . "$ENVF" && set +a || true
install -d -m 755 "$APPS" "$STACK"

# منافذ فاضية تلقائيًا
in_use(){ ss -ltn 2>/dev/null|awk '{print $4}'|sed -n 's/.*:\([0-9]\+\)$/\1/p'|grep -qx "$1" || netstat -ltn 2>/dev/null|awk '{print $4}'|sed -n 's/.*:\([0-9]\+\)$/\1/p'|grep -qx "$1"; }
pick(){ p="$1"; while in_use "$p"; do p=$((p+1)); done; echo "$p"; }

BEH_PORT=${BEH_PORT:-$(pick 8095)}
MOB_PORT=${MOB_PORT:-$(pick 8096)}
RELX_PORT=${RELX_PORT:-$(pick 8097)}

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# ============ 1) behavioral-analytics ============
install -d -m 755 "$APPS/behavioral-analytics"
cat >"$APPS/behavioral-analytics/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
numpy==1.26.4
python-dateutil==2.9.0.post0
R
cat >"$APPS/behavioral-analytics/app.py"<<'PY'
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
PY
cat >"$APPS/behavioral-analytics/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8095
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8095"]
D

# ============ 2) mobility-analytics ============
install -d -m 755 "$APPS/mobility-analytics"
cat >"$APPS/mobility-analytics/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
numpy==1.26.4
python-dateutil==2.9.0.post0
R
cat >"$APPS/mobility-analytics/app.py"<<'PY'
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
PY
cat >"$APPS/mobility-analytics/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8096
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8096"]
D

# ============ 3) relationship-risk ============
install -d -m 755 "$APPS/relationship-risk"
cat >"$APPS/relationship-risk/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
numpy==1.26.4
python-dateutil==2.9.0.post0
R
cat >"$APPS/relationship-risk/app.py"<<'PY'
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
PY
cat >"$APPS/relationship-risk/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8097
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8097"]
D

# ============ Compose ============
cat >"$YML"<<YML
name: ffactory
networks: { $NET: { external: true } }
services:
  behavioral-analytics:
    build: { context: ../apps/behavioral-analytics, dockerfile: Dockerfile }
    container_name: ffactory-behavioral-analytics
    networks: [ $NET ]
    ports: [ "127.0.0.1:${BEH_PORT}:8095" ]
  mobility-analytics:
    build: { context: ../apps/mobility-analytics, dockerfile: Dockerfile }
    container_name: ffactory-mobility-analytics
    networks: [ $NET ]
    ports: [ "127.0.0.1:${MOB_PORT}:8096" ]
  relationship-risk:
    build: { context: ../apps/relationship-risk, dockerfile: Dockerfile }
    container_name: ffactory-relationship-risk
    networks: [ $NET ]
    ports: [ "127.0.0.1:${RELX_PORT}:8097" ]
networks: { $NET: { external: true } }
YML

log "[*] build+up behavior pack"
BEH_PORT="$BEH_PORT" MOB_PORT="$MOB_PORT" RELX_PORT="$RELX_PORT" docker compose -f "$YML" up -d --build

echo "---- READY ----"
echo "behavioral-analytics:  http://127.0.0.1:${BEH_PORT}/health"
echo "mobility-analytics:    http://127.0.0.1:${MOB_PORT}/health"
echo "relationship-risk:     http://127.0.0.1:${RELX_PORT}/health"
