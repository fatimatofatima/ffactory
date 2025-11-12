from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from datetime import datetime, timedelta, timezone
from minio import Minio
from minio.commonconfig import ENABLED, GOVERNANCE, COMPLIANCE, LegalHold
from minio.retention import Retention
import os, requests, io
api=FastAPI()
S3=os.getenv("S3_ENDPOINT","ffactory_minio:9000")
AK=os.getenv("MINIO_ROOT_USER"); SK=os.getenv("MINIO_ROOT_PASSWORD")
SECURE=bool(int(os.getenv("S3_SECURE","0")))
cli=Minio(S3, access_key=AK, secret_key=SK, secure=SECURE)
class PutReq(BaseModel):
    bucket:str="forensic-evidence"; object_name:str; url:str
    retention_days:int|None=365; mode:str|None="COMPLIANCE"; legal_hold:bool|None=True
@api.get("/health")
def health(): return {"status":"ok","endpoint":S3}
@api.post("/ensure_bucket")
def ensure_bucket(bucket:str="forensic-evidence"):
    if not cli.bucket_exists(bucket):
        cli.make_bucket(bucket, object_lock=True)
    return {"bucket":bucket,"object_lock":True}
@api.post("/put_from_url")
def put_from_url(req:PutReq):
    if not cli.bucket_exists(req.bucket):
        cli.make_bucket(req.bucket, object_lock=True)
    r=requests.get(req.url, timeout=120); r.raise_for_status()
    data=io.BytesIO(r.content); data.seek(0)
    until=datetime.now(timezone.utc)+timedelta(days=req.retention_days or 365)
    mode=COMPLIANCE if (req.mode or "COMPLIANCE").upper()=="COMPLIANCE" else GOVERNANCE
    ret=Retention(mode, until)
    cli.put_object(req.bucket, req.object_name, data, length=len(r.content),
                   retention=ret, legal_hold=LegalHold(ENABLED) if req.legal_hold else None)
    stat=cli.stat_object(req.bucket, req.object_name)
    return {"bucket":req.bucket,"object":req.object_name,"version_id":stat.version_id,"retain_until":until.isoformat()}
