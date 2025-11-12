from fastapi import FastAPI
from pydantic import BaseModel
import uvicorn

app = FastAPI(title="ASR Engine")

class AudioRequest(BaseModel):
    audio_url: str

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "asr-engine"}

@app.post("/transcribe")
async def transcribe(request: AudioRequest):
    return {
        "status": "success", 
        "transcription": "نموذج ASR جاهز للتدريب",
        "language": "ar"
    }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
