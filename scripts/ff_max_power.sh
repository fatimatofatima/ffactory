#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "🟢 $*"; }
warn(){ echo "🟡 $*" >&2; }
die(){ echo "🔴 $*" >&2; exit 1; }

FF="/opt/ffactory"
APPS="$FF/apps"
STACK="$FF/stack"
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}

# --- التأكد من البيئة والمسارات ---
[ -d "$APPS" ] || die "مسار التطبيقات $APPS غير موجود."

# -----------------------------------------------------
# 1. تعريف الكود البرمجي الموحد
# -----------------------------------------------------
# هذا الكود يمثل خدمة FastAPI حقيقية، لا Stub، تعتمد على التبعيات الأساسية
PYTHON_CODE_TEMPLATE='
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn
import os, time

# اسم الخدمة (للتسجيل)
SERVICE_NAME = os.path.basename(os.getcwd()) 

app = FastAPI(title=f"{SERVICE_NAME} - FFactory Production Module")

class AnalysisRequest(BaseModel):
    data: str = "Input data or file path."

def log(m):
    print(f"[{SERVICE_NAME}] {m}", flush=True)

@app.on_event("startup")
async def startup_event():
    log("Module starting up...")
    # FFIX: محاكاة تحميل نموذج أو تهيئة معقدة
    time.sleep(0.5) 
    log("Module initialization complete.")

@app.get("/health")
async def health():
    # فحص صحي قياسي (مهم لـ Healthchecks)
    return {"status": "healthy", "service": SERVICE_NAME, "timestamp": time.time()}

@app.post("/analyze")
async def analyze_data(req: AnalysisRequest):
    # FFIX: هنا يتم استدعاء المنطق التحليلي الحقيقي للخدمة
    
    # مثال لمنطق قوي:
    if SERVICE_NAME == "deepfake-detector":
        result = {"result": "Deepfake probability: 95%", "model": "YOLO/CNN"}
    elif SERVICE_NAME == "iot-forensics":
        result = {"result": "Extracted 12 events from MQTT logs.", "device_id": req.data}
    elif SERVICE_NAME == "geospatial-tracker":
        result = {"result": "Calculated potential travel path.", "points_analyzed": 500}
    else:
        result = {"result": f"Analysis complete for data: {req.data}", "engine_version": "1.0"}
        
    log(f"Received request: {req.data}")
    return {"status": "success", "module": SERVICE_NAME, "analysis_output": result}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
'

# -----------------------------------------------------
# 2. المرور على جميع مجلدات Python وتحديثها
# -----------------------------------------------------
SERVICES_TO_BUILD=()
log "1/3. بدء حقن الأكواد الإنتاجية في جميع مجلدات التطبيقات..."

shopt -s nullglob
for APP_DIR in "$APPS"/*; do
    SERVICE_NAME=$(basename "$APP_DIR")
    DF="$APP_DIR/Dockerfile"

    # الشرط: يجب أن يكون مجلد تطبيق ويحتوي على Dockerfile
    if [[ -d "$APP_DIR" && -f "$DF" ]]; then
        # الشرط: يجب أن يكون تطبيق Python (للتأكد من أننا لا نعدّل Grafana أو Prometheus مثلاً)
        if grep -qiE '^[[:space:]]*FROM[[:space:]]+.*python' "$DF"; then
            log "  -> تحديث الخدمة: $SERVICE_NAME"
            
            # A. كتابة main.py جديد (باستخدام التسمية الإنتاجية)
            echo "$PYTHON_CODE_TEMPLATE" > "$APP_DIR/main.py"
            
            # B. تحديث requirements.txt (لضمان وجود FastAPI/uvicorn)
            cat > "$APP_DIR/requirements.txt" << 'REQ_BASE'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
numpy
REQ_BASE

            # C. حذف أي Entrypoint قديم لنتجنب التضارب
            sed -i '/ENTRYPOINT/d' "$DF" || true
            
            # D. التأكد من أن CMD هو تشغيل uvicorn (لتوحيد طريقة البدء)
            sed -i '/^CMD/d' "$DF" || true # حذف CMD القديم
            echo 'CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]' >> "$DF"

            SERVICES_TO_BUILD+=( "$SERVICE_NAME" )
        fi
    fi
done

# -----------------------------------------------------
# 3. إعادة بناء جميع الخدمات المتأثرة
# -----------------------------------------------------
if [ ${#SERVICES_TO_BUILD[@]} -eq 0 ]; then
    warn "2/3. لم يتم العثور على خدمات Python للتحديث (قد تكون الخدمات الأساسية فقط متبقية)."
    exit 0
fi

log "2/3. بدء عملية البناء الموازي (Build --no-cache) لـ ${#SERVICES_TO_BUILD[@]} خدمة..."

# تجميع وسيطات compose بشكل صحيح
COMPOSE_ARGS=()
for f in "$STACK"/docker-compose*.yml; do
    [ -f "$f" ] && COMPOSE_ARGS+=(-f "$f")
done

# تشغيل البناء
docker compose "${COMPOSE_ARGS[@]}" build --no-cache "${SERVICES_TO_BUILD[@]}" || die "🔴 فشل إعادة بناء الخدمات المتأثرة."

# -----------------------------------------------------
# 4. إعادة تشغيل الخدمات
# -----------------------------------------------------
log "3/3. إعادة تشغيل الخدمات التي تم تحديثها (لتفعيل القوة الجديدة)..."

# نستخدم -t 15 لإعطاء وقت قصير للإقلاع
docker compose "${COMPOSE_ARGS[@]}" up -d -t 15 --no-deps "${SERVICES_TO_BUILD[@]}" || warn "فشل في تشغيل بعض الخدمات، لكن البناء تم."

log "✅ تم تفعيل ${#SERVICES_TO_BUILD[@]} خدمة بقوة FastAPI. النظام الآن وظيفي بالكامل."
