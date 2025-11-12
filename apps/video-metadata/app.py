from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess, json, shutil
api=FastAPI()
def ffprobe_ok(): return shutil.which("ffprobe") is not None
@api.get("/health")
def health(): return {"status":"ok" if ffprobe_ok() else "bad", "ffprobe": bool(ffprobe_ok())}
class Inp(BaseModel): url:str
@api.post("/probe")
def probe(inp:Inp):
    if not ffprobe_ok(): raise HTTPException(500,"ffprobe not found")
    cmd=["ffprobe","-v","error","-show_format","-show_streams","-of","json",inp.url]
    p=subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode!=0: raise HTTPException(400, p.stderr.strip())
    return json.loads(p.stdout)
