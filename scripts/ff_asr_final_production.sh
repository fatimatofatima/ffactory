#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "🟢 $*"; }
die(){ echo "🔴 $*" >&2; exit 1; }

FF="/opt/ffactory"
APPS="$FF/apps"
APP_DIR="$APPS/asr-engine"

# --- التأكد من البيئة والمسارات ---
[ -d "$APP_DIR" ] || die "مسار التطبيق $APP_DIR غير موجود."

# -----------------------------------------------------
# 1. تثبيت Dockerfile الصلب (يحل مشكلة Torch و CMD)
# -----------------------------------------------------
log "1/3. تثبيت Dockerfile صلب (مع تثبيت Torch CPU لتجنب مشاكل GPU)..."
cat > "$APP_DIR/Dockerfile" << 'DOCKERFILE'
# /opt/ffactory/apps/asr-engine/Dockerfile
FROM python:3.11-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg git libsndfile1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .

# FFIX: Torch CPU للـ pyannote، ثم بقية المتطلبات
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir torch==2.3.1+cpu torchaudio==2.3.1+cpu \
        -f https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir -r requirements.txt

COPY . .
# متغيرات لتسريع تحميل النماذج
ENV HF_HUB_ENABLE_HF_TRANSFER=1 \
    CT2_USE_MMAP=1
# التشغيل النهائي (نعتمد على uvicorn في requirements.txt)
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8080"]
DOCKERFILE

# -----------------------------------------------------
# 2. تثبيت requirements.txt المضبوط
# -----------------------------------------------------
log "2/3. تثبيت requirements.txt المضبوط..."
cat > "$APP_DIR/requirements.txt" << 'REQ_TXT'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
numpy<2.0
soundfile
librosa>=0.10.1
# ASR سريع
ctranslate2>=4.3
faster-whisper>=1.0
# Diarization (مُثبت بتحديد الإصدار)
pyannote.audio==3.1.1
REQ_TXT

# -----------------------------------------------------
# 3. تثبيت main.py المصحح (مع معالجة استخراج PyAnnote)
# -----------------------------------------------------
log "3/3. تثبيت main.py المصحح (معالجاً أخطاء diarization/tempfile)..."
cat > "$APP_DIR/main.py" << 'PYTHON_MAIN'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, requests, tempfile, uvicorn # FFIX: إضافة tempfile, uvicorn
from typing import List, Optional

# FFIX: يجب أن تكون النماذج اختيارية للتشغيل، ونفحص وجودها
try:
    from faster_whisper import WhisperModel
except Exception:
    WhisperModel = None

try:
    from pyannote.audio import Pipeline
    import torch
except Exception:
    Pipeline = None
    torch = None

# متغيرات البيئة
HF_TOKEN = os.getenv("HUGGINGFACE_TOKEN")
WHISPER_MODEL_ID = os.getenv("WHISPER_MODEL_ID", "medium")
DEVICE = "cuda" if (torch and torch.cuda.is_available()) else "cpu"

app = FastAPI(title="ASR Engine - Production Quality")

WHISPER_MODEL = None
DIARIZATION_PIPELINE = None

class TranscriptionRequest(BaseModel):
    audio_url: str
    language: str = "ar"

def log(m): print(f"[ASR] {m}", flush=True)

@app.on_event("startup")
async def startup():
    global WHISPER_MODEL, DIARIZATION_PIPELINE
    log(f"Starting on Device: {DEVICE}")

    # --- 1. Whisper Model ---
    try:
        if WhisperModel is None:
            raise RuntimeError("faster-whisper library missing")
        compute = "int8" if DEVICE == "cpu" else "int8_float16"
        WHISPER_MODEL = WhisperModel(WHISPER_MODEL_ID, device=DEVICE, compute_type=compute)
        log(f"Whisper loaded: {WHISPER_MODEL_ID} on {DEVICE}")
    except Exception as e:
        log(f"Whisper load failed: {e}")

    # --- 2. PyAnnote Diarization ---
    if HF_TOKEN and Pipeline:
        try:
            DIARIZATION_PIPELINE = Pipeline.from_pretrained(
                "pyannote/speaker-diarization-3.1",
                use_auth_token=HF_TOKEN
            )
            if DEVICE == "cuda":
                DIARIZATION_PIPELINE.to("cuda")
            log("Diarization pipeline ready")
        except Exception as e:
            log(f"Diarization load failed: {e}")
    else:
        log("Diarization disabled (Missing HF_TOKEN or Pipeline library).")

@app.get("/health")
def health():
    return {
        "status":"ok",
        "whisper_ready": bool(WHISPER_MODEL),
        "diarization_ready": bool(DIARIZATION_PIPELINE)
    }

@app.post("/transcribe")
def transcribe(req: TranscriptionRequest):
    if WHISPER_MODEL is None:
        raise HTTPException(503, "Whisper service is unavailable.")

    # --- 1. تنزيل الملف ---
    try:
        r = requests.get(req.audio_url, stream=True, timeout=30)
        r.raise_for_status()
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            for chunk in r.iter_content(8192):
                f.write(chunk)
            audio_path = f.name
    except Exception as e:
        raise HTTPException(400, f"Fetch audio failed: {e}")

    # --- 2. التفريغ (Transcription) ---
    try:
        segs, info = WHISPER_MODEL.transcribe(audio_path, beam_size=5, language=req.language)
        text = "".join(s.text for s in segs)
    except Exception as e:
        os.unlink(audio_path)
        raise HTTPException(500, f"Transcription failed: {e}")

    # --- 3. Diarization (اختياري) ---
    diar = None
    if DIARIZATION_PIPELINE:
        try:
            # FFIX: استخراج صحيح لـ segment, _, label من itertracks
            diar_raw = DIARIZATION_PIPELINE(audio_path)
            diar = []
            for segment, _, label in diar_raw.itertracks(yield_label=True):
                diar.append({
                    "speaker": label,
                    "start": segment.start,
                    "end": segment.end
                })
        except Exception as e:
            log(f"Diarization failed: {e}")

    os.unlink(audio_path)
    return {"text": text, "diarization": diar}

# FFIX: إزالة if __name__ == "__main__" وتشغيل uvicorn عبر CMD
PYTHON_MAIN

# -----------------------------------------------------
# 4. بناء الصورة والتنظيف
# -----------------------------------------------------
log "4/4. بدء عملية البناء (Build --no-cache) لـ ASR Engine..."

# نعتمد على أن ملفات Compose الأساسية قد تم إعدادها مسبقاً في المسار /opt/ffactory/stack/
# docker compose build --no-cache asr-engine

# نستخدم docker build المباشر كما هو مقترح لضمان العزل
docker build -t ff-asr:latest "$APP_DIR" || die "🔴 فشل إعادة بناء صورة ASR Engine."

log "✅ تم بناء صورة ff-asr:latest بقوة إنتاجية."
log "الخطوة التالية: تشغيل الصورة الجديدة."

