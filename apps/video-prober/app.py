from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess, json
api=FastAPI()
class Req(BaseModel): video_url:str
@api.get("/health")
def health(): return {"status":"ok","ffprobe":"cli"}
@api.post("/probe")
def probe(r:Req):
    try:
        p=subprocess.run(["ffprobe","-v","quiet","-print_format","json","-show_format","-show_streams",r.video_url],
                         capture_output=True, text=True, timeout=120)
        if p.returncode!=0: raise Exception(p.stderr)
        return json.loads(p.stdout)
    except Exception as e:
        raise HTTPException(400, str(e))
