#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory; APPS=$FF/apps; STACK=$FF/stack; NET=ffactory_ffactory_net
ENVF=$FF/.env
[ -f "$ENVF" ] || die ".env غير موجود"
install -d -m 755 "$APPS/vision-engine" "$APPS/media-forensics" "$APPS/hashset-service"

# -------- Vision: كشف فيديو --------
cat >"$APPS/vision-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, requests, cv2, time
from PIL import Image
from ultralytics import YOLO

api=FastAPI()
MODEL=os.getenv("VISION_MODEL","yolov8n.pt"); READY=False; ERR=""
try: yolo=YOLO(MODEL); READY=True
except Exception as e: ERR=str(e)

class ImgReq(BaseModel): image_url:str; conf:float|None=0.25
class VidReq(BaseModel): video_url:str; conf:float|None=0.25; stride_sec:float|None=0.5; max_frames:int|None=200

@api.get("/health")
def health(): return {"ready":READY,"model":MODEL,"error":(ERR or None)}

@api.post("/detect")
def detect(inp:ImgReq):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    try:
        r=requests.get(inp.image_url, timeout=30); r.raise_for_status()
        im=Image.open(io.BytesIO(r.content)).convert("RGB")
        res=yolo.predict(im, conf=inp.conf or 0.25, verbose=False)[0]
        out=[{"cls_id":int(b.cls[0]),
              "cls":res.names.get(int(b.cls[0]), str(int(b.cls[0]))),
              "conf":float(b.conf[0]),
              "xywh":[float(x) for x in b.xywh[0].tolist()]} for b in res.boxes]
        return {"detections":out}
    except Exception as e: raise HTTPException(500, str(e))

@api.post("/detect_video")
def detect_video(inp:VidReq):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    cap=cv2.VideoCapture(inp.video_url)
    if not cap.isOpened(): raise HTTPException(400,"cannot open video")
    fps=cap.get(cv2.CAP_PROP_FPS) or 25.0
    step=max(int((inp.stride_sec or 0.5)*fps),1)
    conf=inp.conf or 0.25
    frames=0; dets=0; classes={}
    try:
        idx=0
        while True:
            ok,frame=cap.read()
            if not ok: break
            if idx%step==0:
                res=yolo.predict(frame, conf=conf, verbose=False)[0]
                c=len(res.boxes); dets+=c; frames+=1
                for b in res.boxes:
                    cid=int(b.cls[0])
                    classes[cid]=classes.get(cid,0)+1
                if frames >= (inp.max_frames or 200): break
            idx+=1
    finally:
        cap.release()
    return {"frames_processed":frames,"detections":dets,"classes":classes}
PY

# -------- Media-Forensics: PRNU + تقرير مرئي --------
cat >"$APPS/media-forensics/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, base64, requests, numpy as np, cv2
from PIL import Image, ImageChops
import imagehash, exifread

api=FastAPI()

class ImgReq(BaseModel):
    image_url:str
    ela_quality:int|None=90
    heatmap:bool|None=False

class PrnuReq(BaseModel):
    image_url:str
    return_residual:bool|None=False

@api.get("/health")
def health(): return {"status":"ok"}

def _fetch(url)->bytes:
    r=requests.get(url, timeout=30); r.raise_for_status(); return r.content

def _pil(b): return Image.open(io.BytesIO(b)).convert('RGB')

def ela(img,q=90):
    buf=io.BytesIO(); img.save(buf,'JPEG',quality=q)
    comp=Image.open(io.BytesIO(buf.getvalue()))
    diff=ImageChops.difference(img.convert('RGB'), comp.convert('RGB'))
    arr=np.asarray(diff, dtype=np.int16)
    return diff, float(np.abs(arr).mean()), float(np.percentile(np.abs(arr),95))

def prnu_residual(img_rgb):
    g=np.array(img_rgb.convert('L'), dtype=np.float32)/255.0
    den=cv2.fastNlMeansDenoising((g*255).astype(np.uint8), None, h=7, templateWindowSize=7, searchWindowSize=21).astype(np.float32)/255.0
    resid=g-den
    r=resid - resid.mean()
    r/= (r.std()+1e-8)
    return r

def prnu_strength(r):
    # مقياس بسيط لقوة البصمة
    return float(np.mean(r**2))

@api.post("/analyze")
def analyze(inp:ImgReq):
    try:
        raw=_fetch(inp.image_url); img=_pil(raw); w,h=img.size
        diff, m, p95 = ela(img, inp.ela_quality or 90)
        r = prnu_residual(img); p_strength=prnu_strength(r)
        nrg=float(np.mean((np.array(img.convert('L'),dtype=np.float32)/255.0 - cv2.GaussianBlur(np.array(img.convert('L'),dtype=np.float32)/255.0,(0,0),1.0))**2))
        ah=str(imagehash.average_hash(img)); ph=str(imagehash.phash(img))
        try:
            tags=exifread.process_file(io.BytesIO(raw), details=False)
            keep=("EXIF DateTimeOriginal","EXIF LensModel","Image Make","Image Model","GPS GPSLatitude","GPS GPSLongitude")
            exif={k:str(v) for k,v in tags.items() if k in keep}
        except: exif={}
        out={"width":w,"height":h,"ela_mean":m,"ela_p95":p95,"prnu_strength":p_strength,
             "noise_energy":nrg,"ahash":ah,"phash":ph,"exif":exif}
        if inp.heatmap:
            b=io.BytesIO(); Image.fromarray(((r-r.min())/(r.max()-r.min()+1e-8)*255).astype(np.uint8)).save(b,'PNG')
            out["prnu_residual_png_b64"]=base64.b64encode(b.getvalue()).decode()
            b2=io.BytesIO(); diff.save(b2,'PNG'); out["ela_heatmap_png_b64"]=base64.b64encode(b2.getvalue()).decode()
        return out
    except Exception as e:
        raise HTTPException(500, str(e))

@api.post("/prnu")
def prnu(inp:PrnuReq):
    try:
        raw=_fetch(inp.image_url); img=_pil(raw)
        r=prnu_residual(img); s=prnu_strength(r)
        out={"prnu_strength":s}
        if inp.return_residual:
            b=io.BytesIO(); Image.fromarray(((r-r.min())/(r.max()-r.min()+1e-8)*255).astype(np.uint8)).save(b,'PNG')
            out["residual_png_b64"]=base64.b64encode(b.getvalue()).decode()
        return out
    except Exception as e:
        raise HTTPException(500, str(e))
PY

# -------- Hashset: حالة قاعدة NSRL --------
cat >"$APPS/hashset-service/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, hashlib, requests, sqlite3, ssdeep, csv, gzip, bz2
api=FastAPI()
DB=os.getenv("NSRL_DB_PATH","/data/hashsets/nsrl.sqlite")
os.makedirs(os.path.dirname(DB), exist_ok=True)
def db(): return sqlite3.connect(DB)
def db_init():
    con=db(); cur=con.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS nsrl(sha1 TEXT PRIMARY KEY)")
    cur.execute("PRAGMA journal_mode=WAL"); con.commit(); con.close()
db_init()
class FileReq(BaseModel): file_url:str
class LoadReq(BaseModel): nsrl_url:str
@api.get("/health") 
def health():
    con=db(); cur=con.execute("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='nsrl'")
    ok=cur.fetchone()[0]==1; con.close(); return {"status":"ok","nsrl_ready":ok}
def fetch(url)->bytes:
    r=requests.get(url, timeout=600); r.raise_for_status(); return r.content
@api.post("/hash")
def do_hash(req:FileReq):
    b=fetch(req.file_url)
    return {"md5":hashlib.md5(b).hexdigest(),"sha1":hashlib.sha1(b).hexdigest(),
            "sha256":hashlib.sha256(b).hexdigest(),"ssdeep":ssdeep.hash(b)}
@api.post("/nsrl/load")
def nsrl_load(req:LoadReq):
    raw=fetch(req.nsrl_url)
    if req.nsrl_url.endswith(".gz"): raw=gzip.decompress(raw)
    if req.nsrl_url.endswith(".bz2"): raw=bz2.decompress(raw)
    con=db(); cur=con.cursor(); cur.execute("BEGIN"); ins=0
    try:
        for row in csv.DictReader(io.StringIO(raw.decode(errors="ignore"))):
            sha=(row.get("SHA-1") or row.get("sha1") or row.get("SHA1") or "").strip().upper()
            if len(sha)==40: cur.execute("INSERT OR IGNORE INTO nsrl(sha1) VALUES(?)",(sha,)); ins+=1
        con.commit()
    finally: con.close()
    return {"inserted":ins}
@api.get("/nsrl/check")
def nsrl_check(sha1:str):
    con=db(); cur=con.execute("SELECT 1 FROM nsrl WHERE sha1=? LIMIT 1;",(sha1.upper(),)); ok = cur.fetchone() is not None; con.close()
    return {"present":ok}
@api.get("/nsrl/status")
def nsrl_status():
    con=db(); cur=con.execute("SELECT count(*) FROM nsrl"); n=cur.fetchone()[0]; con.close(); return {"count":int(n)}
PY

# -------- Build + Up فقط للخدمات المتأثرة --------
log "build+up vision/media/hashset"
docker compose --env-file "$ENVF" -f "$STACK/docker-compose.apps.ext.yml" up -d --build vision-engine media-forensics hashset-service

# -------- تحقق مختصر --------
log "docker ps snapshot (2 أسطر)"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep '^ffactory_' | head -n 2 || true
log "health"
for p in 8081 8082 8083; do curl -fsS "http://127.0.0.1:${p}/health" >/dev/null || echo "FAIL /health :${p}"; done
log "done."
