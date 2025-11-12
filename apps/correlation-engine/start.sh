#!/usr/bin/env bash
set -euo pipefail
for i in {1..30}; do
  python - <<'PY' && break || sleep 2
import os, psycopg2
from neo4j import GraphDatabase
PG=os.getenv("DB_URL","postgresql://forensic_user:STRONG_PASS@db:5432/forensic_db")
NEO=os.getenv("NEO4J_URI","bolt://neo4j:7687")
auth_env=os.getenv("NEO4J_AUTH","none")
auth=None if auth_env.lower()=="none" else tuple(auth_env.split(":",1))
psycopg2.connect(PG, connect_timeout=3).close()
GraphDatabase.driver(NEO, auth=auth).verify_connectivity()
print("ok")
PY
done
exec uvicorn correlation_service:app --host 0.0.0.0 --port 8005
