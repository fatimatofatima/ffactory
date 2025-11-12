import os
import json
import psycopg2
import psycopg2.extras as pgx
from neo4j import GraphDatabase, basic_auth
from typing import Dict, List, Any, Optional
from datetime import datetime, time
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("CorrelationEngine")

# --- البيئة والاتصالات (يتم سحبها من Compose) ---
DB_URL = os.getenv("DB_URL", "postgresql://forensic_user:password@db:5432/forensic_db")
NEO4J_URI = os.getenv("NEO4J_URI", "bolt://neo4j:7687")
NEO4J_AUTH_ENV = os.getenv("NEO4J_AUTH", "none")

def _parse_neo4j_auth(auth_env: str) -> Optional[tuple]:
    auth_env = (auth_env or "").strip()
    if not auth_env or auth_env.lower() == "none": return None
    if ":" in auth_env: return tuple(auth_env.split(":", 1))
    return None

class CorrelationEngine:
    def __init__(self):
        self.db_conn = None
        self.neo4j_driver = None
        self._connect_databases()
        self._setup_neo4j_constraints()
    
    def _connect_databases(self):
        try:
            self.db_conn = psycopg2.connect(DB_URL, connect_timeout=5, application_name="correlation_engine")
            auth = _parse_neo4j_auth(NEO4J_AUTH_ENV)
            self.neo4j_driver = GraphDatabase.driver(NEO4J_URI) if auth is None else GraphDatabase.driver(NEO4J_URI, auth=auth)
            self.neo4j_driver.verify_connectivity()
            logger.info("✅ DB connections ready.")
        except Exception as e:
            logger.error(f"❌ Failed to connect to DB/Neo4j: {e}")
            raise

    def _setup_neo4j_constraints(self):
        with self.neo4j_driver.session() as session:
            session.run("CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;")
            session.run("CREATE INDEX file_hash IF NOT EXISTS FOR (f:File) ON (f.hash);")
            session.run("CREATE INDEX event_ts IF NOT EXISTS FOR (e:TimelineEvent) ON (e.timestamp);")
            logger.info("✅ Neo4j constraints set.")

    def close(self):
        if self.db_conn: self.db_conn.close()
        if self.neo4j_driver: self.neo4j_driver.close()

    def _extract_entities_from_postgres(self, case_id: str) -> Dict[str, list]:
        """سحب البيانات الجنائية من Postgres."""
        with self.db_conn.cursor(cursor_factory=pgx.DictCursor) as cur:
            cur.execute("SELECT * FROM timeline_events WHERE case_id = %s ORDER BY timestamp ASC LIMIT 100", (case_id,))
            timeline_events = [dict(row) for row in cur.fetchall()]
            
            cur.execute("SELECT * FROM decryption_failures WHERE case_id = %s", (case_id,))
            failures = [dict(row) for row in cur.fetchall()]

            cur.execute("SELECT * FROM scan_results WHERE case_id = %s", (case_id,))
            scans = [dict(row) for row in cur.fetchall()]

        return {"timeline": timeline_events, "failures": failures, "scans": scans}

    def _build_initial_graph(self, entities: Dict[str, list], case_id: str) -> None:
        """بناء الرسم البياني في Neo4j (مع UNWIND)."""
        with self.neo4j_driver.session() as session:
            # 1. تحميل حالات الفشل
            failure_rows = [{"id": str(f["failure_id"]), "type": f["failure_type"], "ts": f["failure_timestamp"].isoformat(), "case_id": case_id} for f in entities["failures"]]
            if failure_rows:
                 session.run("""UNWIND $rows AS r 
                                MERGE (fail:Failure {id: r.id}) 
                                SET fail += r, fail.severity = CASE WHEN r.type = 'CUSTOM_PROTECTION' THEN 'CRITICAL' ELSE 'HIGH' END 
                                MERGE (c:Case {id: r.case_id}) 
                                MERGE (c)-[:HAD_FAILURE]->(fail)""", rows=failure_rows)

            # 2. تحميل نتائج المسح
            scan_rows = [{"sha256": s["sha256"], "score": int(s["score"]), "family": s["family"], "case_id": case_id, "job_id": str(s["job_id"])} for s in entities["scans"] if s.get("sha256")]
            if scan_rows:
                session.run("""UNWIND $rows AS r 
                                MERGE (f:File {hash: r.sha256}) 
                                SET f += r 
                                MERGE (c:Case {id: r.case_id}) 
                                MERGE (c)-[:INVOLVES_FILE]->(f)""", rows=scan_rows)
            
            # 3. تحميل الأحداث الزمنية (Timeline Events)
            timeline_rows = [{"id": str(t["id"]), "ts": t["timestamp"].isoformat(), "desc": t["description"], "case_id": case_id} for t in entities["timeline"]]
            if timeline_rows:
                session.run("""UNWIND $rows AS r
                                MERGE (e:TimelineEvent {id: r.id})
                                SET e += r 
                                MERGE (c:Case {id: r.case_id}) 
                                MERGE (c)-[:HAS_EVENT]->(e)""", rows=timeline_rows)
            logger.info(f"✅ Graph built with {len(failure_rows)} failures and {len(scan_rows)} files.")

    # ----------------------------------------------------------
    # --- وحدة التفكير النقدي (Mindset Logic) ---
    # ----------------------------------------------------------

    def _generate_investigator_hypotheses(self, case_id: str, entities: Dict[str, list]) -> List[Dict[str, Any]]:
        hypotheses = []
        
        # 1. القاعدة I: التغطية المتعمدة (CUSTOM_PROTECTION)
        custom_fail_count = sum(1 for f in entities.get("failures", []) if f.get("failure_type") == 'CUSTOM_PROTECTION')
        if custom_fail_count >= 1: # نغيرها لـ 1 لأننا نبحث عن أي دليل
            hypotheses.append({
                "severity": "CRITICAL", "type": "التغطية المتعمدة",
                "reason": f"تم تسجيل {custom_fail_count} محاولة لحماية مخصصة/تشويش.",
                "evidence_count": custom_fail_count, "confidence": 0.85
            })

        # 2. القاعدة III: التناقض الزمني (Temporal Inconsistency)
        with self.neo4j_driver.session() as session:
            # البحث عن حدث حذف ملف (الخفي) حدث بعد فشل (الظاهر)
            query_inconsistency = """
            MATCH (f:Failure)
            OPTIONAL MATCH (f)-[:RELATED_TO*1..2]-(t:TimelineEvent)
            WHERE t.description CONTAINS 'File Deletion' AND t.timestamp > f.timestamp
            WITH COUNT(t) AS suspicious_deletions
            RETURN suspicious_deletions
            """
            inconsistency_check = session.run(query_inconsistency).single()
            
            if inconsistency_check and inconsistency_check['suspicious_deletions'] > 0:
                 hypotheses.append({
                    "severity": "HIGH", "type": "التناقض الزمني",
                    "reason": "تم حذف دليل خطير مباشرة بعد فشل فك التشفير. يجب فحص نية المحو.",
                    "evidence_count": inconsistency_check['suspicious_deletions'], "confidence": 0.80
                })

        return hypotheses

    def _find_suspicious_paths(self) -> List[Dict[str, Any]]:
        """إيجاد المسارات المشبوهة في الرسم البياني."""
        query = """
        MATCH path = (f:File)-[*1..3]-(fail:Failure)
        WHERE f.risk_score > 70 AND fail.severity = 'CRITICAL'
        RETURN [n IN nodes(path) | labels(n)[0] + ':' + coalesce(n.hash, n.id)] AS path_summary, length(path) AS path_len
        LIMIT 5
        """
        with self.neo4j_driver.session() as session:
            return [rec.data() for rec in session.run(query)]

    def run_correlation(self, case_id: str) -> Dict[str, Any]:
        """دالة التشغيل الرئيسية المحدثة - المحقق الافتراضي."""
        logger.info(f"🔍 بدء التحليل الاستخباراتي للقضية: {case_id}")
        
        entities = self._extract_entities_from_postgres(case_id)
        self._build_initial_graph(entities, case_id)
        
        hypotheses = self._generate_investigator_hypotheses(case_id, entities)
        suspicious_paths = self._find_suspicious_paths()
        
        return {
            "status": "SUCCESS",
            "case_id": case_id,
            "analysis_timestamp": datetime.now().isoformat(),
            "critical_hypotheses": hypotheses,
            "suspicious_paths_found": len(suspicious_paths),
            "suspicious_paths": suspicious_paths,
        }

# تهيئة التطبيق FastAPI
from fastapi import FastAPI, Depends

app = FastAPI(title="Correlation Engine (Mindset)")
engine: Optional[CorrelationEngine] = None

@app.on_event("startup")
def startup_event():
    global engine
    engine = CorrelationEngine()

@app.on_event("shutdown")
def shutdown_event():
    global engine
    if engine:
        engine.close()

@app.get("/health")
def health_check():
    try:
        engine.neo4j_driver.verify_connectivity()
        engine.db_conn.ping() # محاولة فحص الاتصال
        return {"status": "ok", "services": ["Postgres", "Neo4j", "Ready"]}
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return {"status": "degraded", "error": str(e)}

@app.post("/run_etl_for_case")
def run_etl(case_id: str):
    return engine.run_correlation(case_id)

@app.get("/get_hypotheses/{case_id}")
def get_hypotheses(case_id: str):
    entities = engine._extract_entities_from_postgres(case_id)
    return engine._generate_investigator_hypotheses(case_id, entities)
