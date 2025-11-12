#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "🟢 $*"; }
warn(){ echo "🟡 $*" >&2; }
die(){ echo "🔴 $*" >&2; exit 1; }

FF="/opt/ffactory"
APPS="$FF/apps"
STACK="$FF/stack"
APP_DIR="$APPS/asr-engine"
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}

[ -d "$APP_DIR" ] || die "مسار التطبيق $APP_DIR غير موجود."

# -----------------------------------------------------
# 1. تحديث Dockerfile (إضافة تبعيات النظام الحتمية)
# -----------------------------------------------------
log "1/4. تحديث Dockerfile: إضافة FFmpeg و Git (ضروريان للصوتيات والتحميل)..."
# نستخدم sed لضمان الإضافة بعد سطر FROM وقبل أي شيء آخر
sed -i '/^FROM/a RUN apt-get update && apt-get install -y ffmpeg git libsndfile1 && rm -rf /var/lib/apt/lists/* \
    \n# FFIX: تثبيت تبعيات النظام لـ PyAnnote/Whisper' "$APP_DIR/Dockerfile"

# -----------------------------------------------------
# 2. تحديث متطلبات Python
# -----------------------------------------------------
log "2/4. تحديث requirements.txt (Faster-Whisper + PyAnnote)..."
cat > "$APP_DIR/requirements.txt" << 'REQ_ASR'
fastapi>=0.104.0
uvicorn>=0.24.0
# محرك تفريغ فائق السرعة
faster-whisper>=10.3.0 
# لتمييز المتحدثين (يتطلب توكن HF)
pyannote.audio>=3.1.1 
librosa>=0.10.1
# لأجل Pytorch - نعتمد على أن الصورة الأساسية توفره أو يتم جلبه تلقائياً
REQ_ASR

# -----------------------------------------------------
# 3. كتابة كود FastAPI القوي
# -----------------------------------------------------
log "3/4. كتابة كود ASR Engine النهائي (FastAPI مع Whisper)..."

cat > "$APP_DIR/main.py" << 'PYTHON_ASR'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn
import asyncio
import os
import requests
import io

# تبعيات معقدة
try:
    from faster_whisper import WhisperModel
    from pyannote.audio import Pipeline
    import torch
except ImportError as e:
    # سيتم التعامل مع هذا الفشل كوضع "Deactivated"
    WHISPER_MODEL = None
    DIARIZATION_PIPELINE = None
    print(f"[ASR] 🔴 فشل استيراد مكتبات ASR: {e}. العمل في وضع الاستعداد.")

# FFIX: توكن Hugging Face للوصول إلى نماذج PyAnnote
HF_TOKEN = os.environ.get("HUGGINGFACE_TOKEN", "MISSING_TOKEN")

class TranscriptionRequest(BaseModel):
    # نطلب URL بدلاً من المسار المحلي ليتناسب مع MinIO أو أي مصدر خارجي
    audio_url: str 
    language: str = "ar"
    model_size: str = "medium" 

app = FastAPI(title="ASR Engine - Faster Whisper & Diarization")
WHISPER_MODEL = None
DIARIZATION_PIPELINE = None

def log(msg):
    print(f"[ASR] {msg}", flush=True)

@app.on_event("startup")
async def startup_event():
    global WHISPER_MODEL, DIARIZATION_PIPELINE
    log("بدء تحميل نماذج ASR...")

    # 1. تحميل نموذج Whisper
    try:
        device = "cuda" if torch.cuda.is_available() else "cpu"
        log("🟢 تحميل نموذج Whisper على: " + device)
        WHISPER_MODEL = WhisperModel("medium", device=device, compute_type="int8")
    except Exception as e:
        log(f"🔴 فشل تحميل نموذج Whisper: {e}")

    # 2. تحميل PyAnnote Pipeline
    if HF_TOKEN != "MISSING_TOKEN":
        try:
            log("🟢 تحميل نموذج Diarization (باستخدام التوكن).")
            # PyAnnote/speaker-diarization-3.1
            DIARIZATION_PIPELINE = Pipeline.from_pretrained(
                "pyannote/speaker-diarization-3.1", use_auth_token=HF_TOKEN
            )
            if torch.cuda.is_available():
                DIARIZATION_PIPELINE.to(torch.device("cuda"))
        except Exception as e:
            log(f"🔴 فشل تحميل PyAnnote: {e}")
            DIARIZATION_PIPELINE = None
    else:
        log("🟡 PyAnnote معطل. يرجى توفير HUGGINGFACE_TOKEN كمتغير بيئة.")


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "service": "asr-engine",
        "whisper_status": "READY" if WHISPER_MODEL else "FAILED/PENDING",
        "diarization_status": "READY" if DIARIZATION_PIPELINE else "DISABLED"
    }

@app.post("/transcribe")
async def transcribe_audio(req: TranscriptionRequest):
    if WHISPER_MODEL is None:
        raise HTTPException(status_code=503, detail="خدمة Whisper غير متاحة أو قيد التحميل.")
        
    log(f"بدء تفريغ: {req.audio_url}")
    
    # 1. تحميل الملف من URL (مهم للربط بـ MinIO/S3)
    try:
        response = requests.get(req.audio_url, stream=True, timeout=10)
        response.raise_for_status()
        
        # حفظ الملف مؤقتاً للمعالجة (لتلبية متطلبات Faster Whisper و PyAnnote)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_file:
            for chunk in response.iter_content(chunk_size=8192):
                tmp_file.write(chunk)
            audio_path = tmp_file.name
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"فشل تحميل ملف الصوت من المسار: {e}")

    # 2. التفريغ الصوتي (Transcription)
    try:
        segments, _ = WHISPER_MODEL.transcribe(audio_path, beam_size=5, language=req.language)
        transcription = "".join(segment.text for segment in segments)
    except Exception as e:
        os.unlink(audio_path)
        raise HTTPException(status_code=500, detail=f"فشل التفريغ الصوتي: {e}")

    # 3. تمييز المتحدثين (Diarization)
    diarization_result = None
    if DIARIZATION_PIPELINE:
        try:
            diarization_raw = DIARIZATION_PIPELINE(audio_path)
            diarization_result = [
                {"speaker": turn.speaker, "start": turn.start, "end": turn.end}
                for turn in diarization_raw.itertracks(yield_label=True)
            ]
        except Exception as e:
            log(f"🟡 فشل تمييز المتحدثين: {e}")
            
    os.unlink(audio_path) # حذف الملف المؤقت
    
    return {
        "status": "success",
        "full_text": transcription,
        "speaker_diarization": diarization_result if diarization_result else "Diariaztion Failed/Disabled"
    }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
PYTHON_ASR

# -----------------------------------------------------
# 4. إعادة بناء الصورة
# -----------------------------------------------------
log "4/4. إعادة بناء صورة ASR Engine (لاكتساب FFmpeg والتبعيات الجديدة)..."

# نستخدم sed لإزالة أي Entrypoint قديم قد يعيق عمل Dockerfile الجديد
sed -i '/ENTRYPOINT/d' "$APP_DIR/Dockerfile" || true 

# تشغيل البناء
docker compose build --no-cache asr-engine || die "🔴 فشل إعادة بناء صورة ASR Engine."

log "✅ تم تحديث ASR Engine بالكامل. يرجى تزويد HUGGINGFACE_TOKEN في Compose."
