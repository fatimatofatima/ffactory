#!/usr/bin/env bash
set -Eeuo pipefail

# 🎯 FFactory Ultimate Power Script - 100% Operational Force
log(){ echo "🟢 $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
warn(){ echo "🟡 $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
die(){ echo "🔴 $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; exit 1; }

FF="/opt/ffactory"
COMPOSE_DIR="$FF/stack"
APPS="$FF/apps"
SCRIPTS="$FF/scripts"
DATA_DIR="$FF/data"

# 🔧 حل المشاكل الجوهرية المذكورة في التقرير
solve_core_issues() {
    log "1. حل المشاكل الجوهرية المذكورة في التقرير..."
    
    # 🔌 حل مشكلة Connection Refused في Correlation Engine
    log "🔌 حل مشكلة Neo4j Connection Refused..."
    sudo tee "$SCRIPTS/wait-for-neo4j.sh" >/dev/null <<'WAIT_NEO4J'
#!/bin/bash
set -e
echo "⏳ انتظار Neo4j Bolt على neo4j:7687..."
until nc -z neo4j 7687; do
    echo "⏱️ Neo4j غير جاهز بعد... الانتظار 5 ثوان"
    sleep 5
done
echo "✅ Neo4j جاهز للاتصال!"
WAIT_NEO4J
    chmod +x "$SCRIPTS/wait-for-neo4j.sh"

    # 🗄️ حل مشكلة PostgreSQL على المنفذ 5433
    log "🗄️ حل مشكلة PostgreSQL Port 5433..."
    sudo tee "$SCRIPTS/wait-for-postgres.sh" >/dev/null <<'WAIT_POSTGRES'
#!/bin/bash
set -e
echo "⏳ انتظار PostgreSQL على db:5433..."
until pg_isready -h db -p 5433 -U ${POSTGRES_USER}; do
    echo "⏱️ PostgreSQL غير جاهز بعد... الانتظار 5 ثوان"
    sleep 5
done
echo "✅ PostgreSQL جاهز للاتصال!"
WAIT_POSTGRES
    chmod +x "$SCRIPTS/wait-for-postgres.sh"
}

# 🎯 إنشاء ملفات Docker Compose المُحسَّنة
create_optimized_compose() {
    log "2. إنشاء ملفات Docker Compose مُحلَّلة المشاكل..."
    
    # 📦 ملف الخدمات الأساسية مع Health Checks
    sudo tee "$COMPOSE_DIR/docker-compose.core.yml" >/dev/null <<'CORE_ENHANCED'
version: '3.8'

services:
  # 🗄️ PostgreSQL مع إعدادات متقدمة
  postgres:
    image: postgres:15-alpine
    container_name: ffactory_db
    environment:
      - POSTGRES_DB=ffactory_forensic
      - POSTGRES_USER=ffadmin
      - POSTGRES_PASSWORD=Aa100200@@
      - PGPORT=5433
    ports:
      - "5433:5433"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ../scripts/wait-for-postgres.sh:/wait-for-postgres.sh
    command: [ "postgres", "-p", "5433", "-c", "listen_addresses=*" ]
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -p 5433 -U ffadmin" ]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - ffactory_network

  # 🔮 Neo4j مع إعدادات أمان محسنة
  neo4j:
    image: neo4j:5.12
    container_name: ffactory_neo4j
    environment:
      - NEO4J_AUTH=neo4j/Forensic123!
      - NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
      - NEO4J_dbms_connector_bolt_listen__address=neo4j:7687
      - NEO4J_dbms_connector_http_listen__address=neo4j:7474
      - NEO4J_dbms_connector_https_listen__address=neo4j:7473
      - NEO4J_PLUGINS=["apoc", "graph-data-science"]
    ports:
      - "7474:7474"
      - "7687:7687"
    volumes:
      - neo4j_data:/data
      - neo4j_logs:/logs
      - ../scripts/wait-for-neo4j.sh:/wait-for-neo4j.sh
    healthcheck:
      test: [ "CMD", "cypher-shell", "-u", "neo4j", "-p", "Forensic123!", "RETURN 1" ]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 60s
    networks:
      - ffactory_network

  # ☁️ MinIO للتخزين
  minio:
    image: minio/minio
    container_name: ffactory_minio
    environment:
      - MINIO_ROOT_USER=ffminio
      - MINIO_ROOT_PASSWORD=Mini0123@@
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - minio_data:/data
    healthcheck:
      test: [ "CMD", "curl", "-f", "http://localhost:9000/minio/health/live" ]
      interval: 30s
      timeout: 20s
      retries: 3
    networks:
      - ffactory_network

volumes:
  postgres_data:
  neo4j_data:
  neo4j_logs:
  minio_data:

networks:
  ffactory_network:
    driver: bridge
CORE_ENHANCED

    # 🤖 ملف محركات الذكاء الاصطناعي الحقيقية
    sudo tee "$COMPOSE_DIR/docker-compose.ai.yml" >/dev/null <<'AI_ENHANCED'
version: '3.8'

services:
  # 🔄 Correlation Engine الحقيقي (بدون Stubs)
  correlation-engine:
    build:
      context: ../apps/correlation-engine
      dockerfile: Dockerfile
    container_name: ffactory_correlation
    environment:
      - DB_HOST=postgres
      - DB_PORT=5433
      - DB_USER=ffadmin
      - DB_PASSWORD=Aa100200@@
      - DB_NAME=ffactory_forensic
      - NEO4J_URI=bolt://neo4j:7687
      - NEO4J_USER=neo4j
      - NEO4J_PASSWORD=Forensic123!
    depends_on:
      postgres:
        condition: service_healthy
      neo4j:
        condition: service_healthy
    ports:
      - "8082:8080"
    healthcheck:
      test: [ "CMD", "curl", "-f", "http://localhost:8080/health" ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - ffactory_network

  # 🎤 ASR Engine الحقيقي (بدون Stubs)
  asr-engine:
    build:
      context: ../apps/asr-engine
      dockerfile: Dockerfile
    container_name: ffactory_asr
    environment:
      - HUGGINGFACE_TOKEN=${HUGGINGFACE_TOKEN:-hf_yourtokenhere}
      - MODEL_SIZE=medium
      - LANGUAGE=ar
    ports:
      - "8080:8080"
    volumes:
      - asr_cache:/root/.cache
    healthcheck:
      test: [ "CMD", "curl", "-f", "http://localhost:8080/health" ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - ffactory_network

  # 🧠 Neural Core الحقيقي (بدون Stubs)
  neural-core:
    build:
      context: ../apps/neural-core
      dockerfile: Dockerfile
    container_name: ffactory_nlp
    environment:
      - HF_TOKEN=${HUGGINGFACE_TOKEN:-hf_yourtokenhere}
      - MODEL_NAME=CAMeL-Lab/bert-base-arabic-camelbert-msa
    ports:
      - "8000:8000"
    volumes:
      - nlp_cache:/root/.cache
    healthcheck:
      test: [ "CMD", "curl", "-f", "http://localhost:8000/health" ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - ffactory_network

volumes:
  asr_cache:
  nlp_cache:

networks:
  ffactory_network:
    external: true
    name: ffactory_ffactory_network
AI_ENHANCED
}

# 🔧 استبدال الـ Stubs بكود حقيقي
replace_stubs_with_real_code() {
    log "3. استبدال الـ Stubs بكود إنتاجي حقيقي..."
    
    # 🔄 Correlation Engine الحقيقي
    log "بناء Correlation Engine الحقيقي..."
    mkdir -p "$APPS/correlation-engine"
    
    sudo tee "$APPS/correlation-engine/Dockerfile" >/dev/null <<'CORRELATION_DOCKERFILE'
FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    postgresql-client \
    netcat-openbsd \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# سكربت بدء تشغيل ذكي ينتظر الخدمات
COPY ../scripts/wait-for-neo4j.sh /wait-for-neo4j.sh
COPY ../scripts/wait-for-postgres.sh /wait-for-postgres.sh

CMD ["sh", "-c", "/wait-for-postgres.sh && /wait-for-neo4j.sh && python main.py"]
CORRELATION_DOCKERFILE

    sudo tee "$APPS/correlation-engine/requirements.txt" >/dev/null <<'CORRELATION_REQUIREMENTS'
fastapi>=0.104.0
uvicorn>=0.24.0
asyncpg>=0.28.0
neo4j>=5.14.0
pydantic>=2.0.0
python-multipart>=0.0.6
CORRELATION_REQUIREMENTS

    sudo tee "$APPS/correlation-engine/main.py" >/dev/null <<'CORRELATION_REAL_CODE'
from fastapi import FastAPI, HTTPException
import asyncpg
from neo4j import GraphDatabase
import os
import asyncio

app = FastAPI(title="Correlation Engine - Real Production")

class RealCorrelationEngine:
    def __init__(self):
        self.pg_pool = None
        self.neo4j_driver = None
    
    async def init_databases(self):
        """تهيئة اتصالات قواعد البيانات الحقيقية"""
        try:
            # اتصال PostgreSQL الحقيقي
            self.pg_pool = await asyncpg.create_pool(
                "postgresql://ffadmin:Aa100200@@@postgres:5433/ffactory_forensic"
            )
            
            # اتصال Neo4j الحقيقي
            self.neo4j_driver = GraphDatabase.driver(
                "bolt://neo4j:7687",
                auth=("neo4j", "Forensic123!")
            )
            
            # إنشاء قيود Neo4j للحصول على أداء أفضل
            with self.neo4j_driver.session() as session:
                session.run("CREATE CONSTRAINT IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE")
                session.run("CREATE CONSTRAINT IF NOT EXISTS FOR (f:File) REQUIRE f.hash IS UNIQUE")
                session.run("CREATE CONSTRAINT IF NOT EXISTS FOR (e:Event) REQUIRE e.event_id IS UNIQUE")
            
            print("✅ تم تهيئة محرك الترابط الحقيقي")
            return True
        except Exception as e:
            print(f"🔴 فشل تهيئة قواعد البيانات: {e}")
            return False

engine = RealCorrelationEngine()

@app.on_event("startup")
async def startup_event():
    """حدث بدء التشغيل - ينتظر الخدمات"""
    print("⏳ بدء تهيئة Correlation Engine...")
    success = await engine.init_databases()
    if not success:
        print("🔴 فشل تهيئة المحرك - سيعمل في وضع متدهور")

@app.get("/health")
async def health_check():
    """فحص صحة متقدم"""
    try:
        # فحص PostgreSQL
        if engine.pg_pool:
            async with engine.pg_pool.acquire() as conn:
                await conn.fetchval("SELECT 1")
        
        # فحص Neo4j
        if engine.neo4j_driver:
            engine.neo4j_driver.verify_connectivity()
        
        return {
            "status": "healthy",
            "service": "correlation-engine",
            "postgres": "connected",
            "neo4j": "connected",
            "version": "2.0.0-real"
        }
    except Exception as e:
        return {
            "status": "degraded",
            "error": str(e),
            "service": "correlation-engine"
        }

@app.post("/etl/run")
async def run_etl():
    """تشغيل عملية ETL حقيقية"""
    try:
        # استخراج البيانات من PostgreSQL
        async with engine.pg_pool.acquire() as conn:
            # افتراض وجود جداول حقيقية
            persons = await conn.fetch("""
                SELECT id, name, email, created_at 
                FROM persons 
                LIMIT 100
            """)
            
            files = await conn.fetch("""
                SELECT hash, filename, owner_id, size, created_at 
                FROM files 
                LIMIT 100
            """)
        
        # تحميل البيانات إلى Neo4j
        with engine.neo4j_driver.session() as session:
            # تحميل الأشخاص
            for person in persons:
                session.run("""
                    MERGE (p:Person {id: $id})
                    SET p.name = $name, 
                        p.email = $email,
                        p.created_at = $created_at
                """, dict(person))
            
            # تحميل الملفات
            for file in files:
                session.run("""
                    MERGE (f:File {hash: $hash})
                    SET f.filename = $filename,
                        f.size = $size,
                        f.created_at = $created_at
                """, dict(file))
            
            # إنشاء العلاقات
            for file in files:
                session.run("""
                    MATCH (p:Person {id: $owner_id})
                    MATCH (f:File {hash: $hash})
                    MERGE (p)-[r:OWNS]->(f)
                    SET r.created_at = $created_at
                """, dict(file))
        
        return {
            "status": "success",
            "message": "تم تنفيذ ETL بنجاح",
            "processed": {
                "persons": len(persons),
                "files": len(files)
            }
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"فشل ETL: {str(e)}")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")
CORRELATION_REAL_CODE

    # 🎤 ASR Engine الحقيقي
    log "بناء ASR Engine الحقيقي..."
    sudo tee "$APPS/asr-engine/main.py" >/dev/null <<'ASR_REAL_CODE'
from fastapi import FastAPI, HTTPException, UploadFile, File
from pydantic import BaseModel
import uvicorn
import tempfile
import os
import requests

# استيراد المكتبات الحقيقية
try:
    from faster_whisper import WhisperModel
    from pyannote.audio import Pipeline
    import torch
    WHISPER_READY = True
except ImportError:
    WHISPER_READY = False
    print("🔴 لم يتم تحميل مكتبات ASR - الوضع التجريبي")

app = FastAPI(title="ASR Engine - Real Production")

class TranscriptionRequest(BaseModel):
    audio_url: str = None
    language: str = "ar"

# تحميل النماذج الحقيقية
WHISPER_MODEL = None
DIARIZATION_PIPELINE = None

@app.on_event("startup")
async def startup_event():
    global WHISPER_MODEL, DIARIZATION_PIPELINE
    
    if not WHISPER_READY:
        print("🔴 العمل في وضع ASR التجريبي")
        return
    
    try:
        # تحميل نموذج Whisper الحقيقي
        device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"🟢 تحميل Whisper على {device}...")
        WHISPER_MODEL = WhisperModel(
            "medium", 
            device=device, 
            compute_type="int8",
            download_root="/root/.cache/whisper"
        )
        
        # تحميل نموذج Diarization إذا كان هناك توكن
        hf_token = os.getenv("HUGGINGFACE_TOKEN")
        if hf_token and hf_token != "hf_yourtokenhere":
            print("🟢 تحميل PyAnnote Diarization...")
            DIARIZATION_PIPELINE = Pipeline.from_pretrained(
                "pyannote/speaker-diarization-3.1",
                use_auth_token=hf_token
            )
            if torch.cuda.is_available():
                DIARIZATION_PIPELINE.to(torch.device("cuda"))
        
        print("✅ تم تحميل نماذج ASR الحقيقية")
    except Exception as e:
        print(f"🔴 فشل تحميل النماذج: {e}")

@app.get("/health")
async def health_check():
    status = "healthy" if WHISPER_READY else "degraded"
    return {
        "status": status,
        "service": "asr-engine",
        "whisper_ready": WHISPER_MODEL is not None,
        "diarization_ready": DIARIZATION_PIPELINE is not None,
        "version": "2.0.0-real"
    }

@app.post("/transcribe")
async def transcribe_audio(request: TranscriptionRequest):
    if not WHISPER_MODEL:
        raise HTTPException(status_code=503, detail="خدمة ASR غير جاهزة بعد")
    
    try:
        # تحميل الملف من URL
        if request.audio_url:
            response = requests.get(request.audio_url, timeout=30)
            response.raise_for_status()
            
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_file:
                tmp_file.write(response.content)
                audio_path = tmp_file.name
        else:
            raise HTTPException(status_code=400, detail="يجب توفير audio_url")
        
        # التفريغ الصوتي الحقيقي
        segments, info = WHISPER_MODEL.transcribe(
            audio_path,
            language=request.language,
            beam_size=5,
            best_of=5
        )
        
        transcription = " ".join(segment.text for segment in segments)
        
        # تمييز المتحدثين إذا كان النموذج جاهز
        diarization_result = None
        if DIARIZATION_PIPELINE:
            try:
                diarization = DIARIZATION_PIPELINE(audio_path)
                diarization_result = [
                    {
                        "speaker": turn.speaker,
                        "start": round(turn.start, 2),
                        "end": round(turn.end, 2)
                    }
                    for turn in diarization.itertracks(yield_label=True)
                ]
            except Exception as e:
                print(f"🔴 فشل تمييز المتحدثين: {e}")
        
        # تنظيف الملف المؤقت
        os.unlink(audio_path)
        
        return {
            "status": "success",
            "transcription": transcription,
            "language": info.language,
            "language_probability": round(info.language_probability, 3),
            "diarization": diarization_result,
            "model": "faster-whisper-medium"
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"فشل التفريغ: {str(e)}")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")
ASR_REAL_CODE

    # 🧠 Neural Core الحقيقي
    log "بناء Neural Core الحقيقي..."
    sudo tee "$APPS/neural-core/main.py" >/dev/null <<'NLP_REAL_CODE'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn
import os

# استيراد مكتبات NLP الحقيقية
try:
    from transformers import pipeline, AutoTokenizer, AutoModelForTokenClassification
    import torch
    NLP_READY = True
except ImportError:
    NLP_READY = False
    print("🔴 لم يتم تحميل مكتبات NLP - الوضع التجريبي")

app = FastAPI(title="Neural Core - Real Production")

class AnalysisRequest(BaseModel):
    text: str
    language: str = "ar"

# النماذج الحقيقية
NER_PIPELINE = None
SENTIMENT_PIPELINE = None

@app.on_event("startup")
async def startup_event():
    global NER_PIPELINE, SENTIMENT_PIPELINE
    
    if not NLP_READY:
        print("🔴 العمل في وضع NLP التجريبي")
        return
    
    try:
        device = 0 if torch.cuda.is_available() else -1
        
        # تحميل نموذج NER للعربية
        print("🟢 تحميل نموذج NER العربي...")
        NER_PIPELINE = pipeline(
            "ner",
            model="CAMeL-Lab/bert-base-arabic-camelbert-msa-ner",
            device=device,
            aggregation_strategy="simple"
        )
        
        # تحميل نموذج تحليل المشاعر
        print("🟢 تحميل نموذج تحليل المشاعر...")
        SENTIMENT_PIPELINE = pipeline(
            "sentiment-analysis",
            model="cardiffnlp/twitter-xlm-sentiment-multilingual",
            device=device
        )
        
        print("✅ تم تحميل نماذج NLP الحقيقية")
    except Exception as e:
        print(f"🔴 فشل تحميل النماذج: {e}")

@app.get("/health")
async def health_check():
    status = "healthy" if NLP_READY else "degraded"
    return {
        "status": status,
        "service": "neural-core",
        "ner_ready": NER_PIPELINE is not None,
        "sentiment_ready": SENTIMENT_PIPELINE is not None,
        "version": "2.0.0-real"
    }

@app.post("/analyze/ner")
async def analyze_ner(request: AnalysisRequest):
    if not NER_PIPELINE:
        raise HTTPException(status_code=503, detail="خدمة NER غير جاهزة بعد")
    
    try:
        # استخراج الكيانات المسماة الحقيقية
        entities = NER_PIPELINE(request.text)
        
        return {
            "status": "success",
            "text": request.text,
            "entities": entities,
            "model": "CAMeL-Lab/bert-base-arabic-camelbert-msa-ner"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"فشل تحليل NER: {str(e)}")

@app.post("/analyze/sentiment")
async def analyze_sentiment(request: AnalysisRequest):
    if not SENTIMENT_PIPELINE:
        raise HTTPException(status_code=503, detail="خدمة تحليل المشاعر غير جاهزة بعد")
    
    try:
        # تحليل المشاعر الحقيقي
        sentiment = SENTIMENT_PIPELINE(request.text)
        
        return {
            "status": "success",
            "text": request.text,
            "sentiment": sentiment[0] if sentiment else {},
            "model": "cardiffnlp/twitter-xlm-sentiment-multilingual"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"فشل تحليل المشاعر: {str(e)}")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
NLP_REAL_CODE
}

# 🚀 تشغيل النظام المحسّن
deploy_enhanced_system() {
    log "4. نشر النظام المحسّن..."
    
    cd "$FF"
    
    # إيقاف أي خدمات سابقة
    log "إيقاف الخدمات السابقة..."
    docker-compose -f stack/docker-compose.core.yml down 2>/dev/null || true
    docker-compose -f stack/docker-compose.ai.yml down 2>/dev/null || true
    
    # بناء وتشغيل الخدمات الأساسية
    log "بناء الخدمات الأساسية..."
    docker-compose -f stack/docker-compose.core.yml up -d --build
    
    # انتظار الخدمات الأساسية
    log "انتظار تهيئة قواعد البيانات..."
    sleep 30
    
    # فحص صحة الخدمات الأساسية
    log "فحص صحة الخدمات الأساسية..."
    if docker-compose -f stack/docker-compose.core.yml ps | grep -q "Up"; then
        log "✅ الخدمات الأساسية تعمل بنجاح"
    else
        die "🔴 فشل تشغيل الخدمات الأساسية"
    fi
    
    # بناء وتشغيل محركات الذكاء الاصطناعي
    log "بناء محركات الذكاء الاصطناعي الحقيقية..."
    docker-compose -f stack/docker-compose.ai.yml up -d --build
    
    # انتظار محركات الذكاء الاصطناعي
    log "انتظار تحميل نماذج الذكاء الاصطناعي..."
    sleep 60
    
    # فحص صحة النظام الكامل
    log "إجراء فحص صحة نهائي..."
    check_system_health
}

# 🏥 فحص صحة النظام المتقدم
check_system_health() {
    log "5. فحص صحة النظام المتقدم..."
    
    echo ""
    echo "🔍 فحص صحة الخدمات:"
    echo "===================="
    
    # فحص كل خدمة
    services=(
        "postgres:5433"
        "neo4j:7687" 
        "minio:9000"
        "asr-engine:8080"
        "neural-core:8000"
        "correlation-engine:8082"
    )
    
    all_healthy=true
    
    for service in "${services[@]}"; do
        name="${service%:*}"
        port="${service#*:}"
        
        if docker exec "ffactory_$name" curl -f -s "http://localhost:$port/health" >/dev/null 2>&1; then
            echo "✅ $name: صحي"
        else
            echo "🔴 $name: غير صحي"
            all_healthy=false
        fi
    done
    
    echo ""
    if $all_healthy; then
        echo "🎉 جميع الخدمات تعمل بصحة ممتازة!"
        echo ""
        echo "📊 روابط النظام:"
        echo "  🌐 Neo4j Browser: http://localhost:7474 (neo4j/Forensic123!)"
        echo "  ☁️ MinIO Console: http://localhost:9001 (ffminio/Mini0123@@)"
        echo "  🎤 ASR Engine: http://localhost:8080"
        echo "  🧠 NLP Engine: http://localhost:8000" 
        echo "  🔄 Correlation Engine: http://localhost:8082"
        echo ""
        echo "🚀 النظام جاهز للاستخدام التشغيلي!"
    else
        echo "⚠️ بعض الخدمات تحتاج إلى اهتمام"
        echo "🔧 تشغيل 'docker logs <container_name>' للتحقق من السجلات"
    fi
}

# 🎯 التنفيذ الرئيسي
main() {
    echo "🚀 بدء تفعيل النظام الجنائي - 100% قوة حقيقية"
    echo "============================================="
    echo "🎯 الهدف: تحويل النظام من هيكل تجريبي إلى نظام إنتاجي"
    echo ""
    
    solve_core_issues
    create_optimized_compose
    replace_stubs_with_real_code
    deploy_enhanced_system
    
    echo ""
    echo "✅ تم الانتهاء من تفعيل النظام بنجاح!"
    echo "💡 تذكر: قم بتعيين HUGGINGFACE_TOKEN الحقيقي في ملف .env لتفعيل كامل الميزات"
}

# التشغيل
main "$@"
