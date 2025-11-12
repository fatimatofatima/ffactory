from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os

app = FastAPI(title="ASR Engine")

class AudioInput(BaseModel):
    file_path: str

@app.post("/transcribe")
def transcribe(audio: AudioInput):
    return {"status": "ASR جاهز", "file": audio.file_path}

@app.get("/health")
def health():
    return {"status": "يعمل"}
