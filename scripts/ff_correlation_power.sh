#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "🟢 $*"; }
warn(){ echo "🟡 $*" >&2; }
die(){ echo "🔴 $*" >&2; exit 1; }

FF="/opt/ffactory"
APPS="$FF/apps"
APP_DIR="$APPS/correlation-engine"
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}

[ -d "$APP_DIR" ] || die "مسار التطبيق $APP_DIR غير موجود."

# -----------------------------------------------------
# 1. تحديث متطلبات Python (Postgres/Neo4j)
# -----------------------------------------------------
log "1/3. تحديث requirements.txt (asyncpg + neo4j)..."

cat > "$APP_DIR/requirements.txt" << 'REQ_CE'
fastapi>=0.104.0
uvicorn>=0.24.0
asyncpg>=0.28.0 # لربط Postgres بشكل غير متزامن
neo4j>=5.14.0  # لربط Neo4j
aiofiles>=23.2.0
REQ_CE

# -----------------------------------------------------
# 2. كتابة كود FastAPI القوي (منطق ETL و Graph Analytics)
# -----------------------------------------------------
log "2/3. كتابة كود Correlation Engine النهائي (ETL إلى Neo4j)..."

cat > "$APP_DIR/main.py" << 'PYTHON_CE'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import asyncpg
from neo4j import GraphDatabase
import os, asyncio

app = FastAPI(title="Correlation Engine - ETL & Graph Analytics")

class CorrelationEngine:
    """
    محرك الترابط: مسؤول عن سحب البيانات من قواعد البيانات العلائقية (Postgres)
    وتحويلها إلى نموذج الرسم البياني (Neo4j) لتمكين التحليل المتقدم.
    """
    def __init__(self):
        self.pg_pool = None
        self.neo4j_driver = None

    async def init_databases(self):
        # 1. إعداد متغيرات الاتصال من البيئة (يجب توفيرها عبر Compose Override)
        PG_USER = os.environ.get("DB_USER", "ffadmin")
        PG_PASS = os.environ.get("DB_PASSWORD", "Aa100200@@")
        PG_HOST = os.environ.get("DB_HOST", "db")
        PG_DB = os.environ.get("DB_NAME", "ffactory")

        NEO4J_USER = os.environ.get("NEO4J_USER", "neo4j")
        NEO4J_PASS = os.environ.get("NEO4J_PASSWORD", "Forensic123!")
        
        # 2. اتصال PostgreSQL
        self.pg_pool = await asyncpg.create_pool(
            f"postgresql://{PG_USER}:{PG_PASS}@{PG_HOST}:5432/{PG_DB}"
        )
        
        # 3. اتصال Neo4j
        self.neo4j_driver = GraphDatabase.driver(
            "bolt://neo4j:7687", 
            auth=(NEO4J_USER, NEO4J_PASS)
        )
        
        # 4. إنشاء قيود Neo4j (لضمان سرعة MERGE)
        with self.neo4j_driver.session() as session:
            session.run("CREATE CONSTRAINT IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE")
            session.run("CREATE CONSTRAINT IF NOT EXISTS FOR (f:File) REQUIRE f.hash IS UNIQUE")
            session.run("CREATE CONSTRAINT IF NOT EXISTS FOR (e:Event) REQUIRE e.event_id IS UNIQUE")
            print("🟢 Neo4j constraints verified.")

    async def extract_from_postgres(self):
        """ محاكاة استخراج البيانات الأولية من Postgres. """
        async with self.pg_pool.acquire() as conn:
            # افتراض جداول: persons (id, name, email), files (hash, owner_id), events (event_id, person_id, file_hash)
            persons = await conn.fetch("SELECT 1 AS id, 'Mohamed' AS name, 'm@mail.com' AS email")
            files = await conn.fetch("SELECT 'hash1' AS hash, 1 AS owner_id, 'report.pdf' AS filename")
            events = await conn.fetch("SELECT 101 AS event_id, 1 AS person_id, 'hash1' AS file_hash, '2025-11-01' AS timestamp")
            
            return persons, files, events
            
    async def load_to_neo4j(self, persons, files, events):
        """ تحويل البيانات إلى Neo4j (ETL Load). """
        with self.neo4j_driver.session() as session:
            # Load Persons
            for person in persons:
                session.run("MERGE (p:Person {id: $id}) SET p.name = $name", dict(person))
                
            # Load Files
            for file in files:
                session.run("MERGE (f:File {hash: $hash}) SET f.filename = $filename", dict(file))
                
            # Create Relationships
            for event in events:
                session.run("""
                    MATCH (p:Person {id: $person_id})
                    MATCH (f:File {hash: $file_hash})
                    MERGE (p)-[r:ACCESSED {timestamp: $timestamp}]->(f)
                """, {"person_id": event['person_id'], "file_hash": event['file_hash'], "timestamp": event['timestamp']})
                
        return len(persons), len(files), len(events)

engine = CorrelationEngine()

@app.on_event("startup")
async def startup():
    # Entrypoint Waiter يضمن أن DBs متاحة TCP، هذا الكود يضمن أنها مُهيأة.
    try:
        await engine.init_databases()
        print("✅ Correlation Engine initialized.")
    except Exception as e:
        print(f"🔴 فشل اتصال قواعد البيانات: {e}. الخدمة تعمل في وضع صحي متدهور.")

@app.get("/health")
async def health():
    status = "healthy"
    try:
        if engine.pg_pool: await engine.pg_pool.fetch("SELECT 1")
        if engine.neo4j_driver: engine.neo4j_driver.verify_connectivity()
    except:
        status = "degraded"
        
    return {"status": status, "service": "correlation-engine", "db_status": status}

@app.post("/run_etl")
async def run_etl():
    """ تشغيل خطوة الترابط الكاملة (Extract, Transform, Load). """
    try:
        persons, files, events = await engine.extract_from_postgres()
        p, f, e = await engine.load_to_neo4j(persons, files, events)
        
        return {
            "status": "success", 
            "message": "ETL process completed.",
            "processed": {"persons": p, "files": f, "events": e}
        }
    except Exception as e:
        return {"error": str(e), "message": "Failed during ETL process."}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
PYTHON_CE

# -----------------------------------------------------
# 3. إعادة بناء الصورة
# -----------------------------------------------------
log "3/3. إعادة بناء صورة Correlation Engine بدون كاش..."

# نستخدم sed لإزالة أي Entrypoint قديم قد يعيق عمل Dockerfile الجديد
sed -i '/ENTRYPOINT/d' "$APP_DIR/Dockerfile" || true 

# تشغيل البناء
docker compose build --no-cache correlation-engine || die "🔴 فشل إعادة بناء صورة Correlation Engine."

log "✅ تم تفعيل Correlation Engine بقوة ETL."
