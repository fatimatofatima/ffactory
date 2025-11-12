from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, base64, requests, numpy as np, cv2
from PIL import Image, ImageChops
import imagehash, exifread
api=FastAPI()
class Inp(BaseModel): image_url:str; ela_quality:int|None=90; heatmap:bool|None=False
@api.get("/health") 
def health(): return {"status":"ok"}
def ela(img,q=90):
    buf=io.BytesIO(); img.save(buf,'JPEG',quality=q)
    comp=Image.open(io.BytesIO(buf.getvalue()))
    diff=ImageChops.difference(img.convert('RGB'), comp.convert('RGB'))
    arr=np.asarray(diff, dtype=np.int16)
    return diff, float(np.abs(arr).mean()), float(np.percentile(np.abs(arr),95))
def noise_energy(img):
    g=np.array(img.convert('L'), dtype=np.float32)/255.0
    resid=g-cv2.GaussianBlur(g,(0,0),1.0); return float(np.mean(resid**2))
def exif_map(raw):
    try:
        tags=exifread.process_file(io.BytesIO(raw), details=False)
        keep=("EXIF DateTimeOriginal","EXIF LensModel","Image Make","Image Model","GPS GPSLatitude","GPS GPSLongitude")
        return {k:str(v) for k,v in tags.items() if k in keep}
    except: return {}
@api.post("/analyze")
def analyze(inp:Inp):
    try:
        r=requests.get(inp.image_url, timeout=30); r.raise_for_status()
        img=Image.open(io.BytesIO(r.content)).convert('RGB'); w,h=img.size
        diff, m, p95 = ela(img, inp.ela_quality or 90)
        nrg=noise_energy(img); ah=str(imagehash.average_hash(img)); ph=str(imagehash.phash(img))
        exif=exif_map(r.content)
        out={"width":w,"height":h,"ela_mean":m,"ela_p95":p95,"noise_energy":nrg,"ahash":ah,"phash":ph,"exif":exif}
        if inp.heatmap:
            b=io.BytesIO(); diff.save(b, format='PNG'); out["ela_heatmap_png_b64"]=base64.b64encode(b.getvalue()).decode()
        return out
    except Exception as e:
        raise HTTPException(500, str(e))
