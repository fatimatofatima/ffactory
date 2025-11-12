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
