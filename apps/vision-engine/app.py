from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, requests
from PIL import Image
from ultralytics import YOLO
api=FastAPI()
MODEL=os.getenv("VISION_MODEL","yolov8n.pt"); READY=False; ERR=""
try: yolo=YOLO(MODEL); READY=True
except Exception as e: ERR=str(e)
class Inp(BaseModel): image_url:str; conf:float|None=0.25
@api.get("/health")
def health(): return {"ready":READY,"model":MODEL,"error":(ERR or None)}
@api.post("/warmup")
def warm(): 
    global READY,ERR
    try: YOLO(MODEL); READY=True; return {"ok":True}
    except Exception as e: ERR=str(e); raise HTTPException(503, ERR)
@api.post("/detect")
def detect(inp:Inp):
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
    except Exception as e:
        raise HTTPException(500, str(e))
