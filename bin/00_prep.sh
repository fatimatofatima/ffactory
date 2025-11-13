#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }
err(){ echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root"
command -v docker >/dev/null || err "Docker missing"
docker compose version >/dev/null 2>&1 || err "Docker Compose plugin missing"

FF=/opt/ffactory; APPS=$FF/apps; STACK=$FF/stack; SCRIPTS=$FF/scripts; LOGS=$FF/logs; DATA=$FF/data
install -d -m 755 "$APPS" "$STACK" "$SCRIPTS" "$LOGS" "$DATA" "$FF/backups"

# .env
if [[ ! -f "$STACK/.env" ]]; then
  cat >"$STACK/.env" <<'ENV'
COMPOSE_PROJECT_NAME=ffactory
FF_NETWORK=ffactory_net
TZ=Asia/Kuwait

NEO4J_USER=neo4j
NEO4J_PASSWORD=StrongPass_2025!
PGUSER=forensic_user
PGPASSWORD=Forensic123!
PGDB=ffactory_core
REDIS_PASSWORD=Redis123!
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=ChangeMe_12345

PGPORT=5433
REDIS_PORT=6379
FRONTEND_PORT=3000
INVESTIGATION_API_PORT=8080
ANALYTICS_PORT=8090
FEEDBACK_API_PORT=8070
AI_REPORT_PORT=8081
NEO4J_HTTP_PORT=7474
NEO4J_BOLT_PORT=7687
OLLAMA_PORT=11435
MINIO_PORT=9002

NEO4J_PLUGINS=["apoc","graph-data-science"]
NEO4J_ACCEPT_LICENSE_AGREEMENT=yes

ADMIN_BOT_TOKEN=REPLACE_ADMIN_TOKEN
REPORTS_BOT_TOKEN=REPLACE_REPORTS_TOKEN
BOT_ALLOWED_USERS=795444729
ENV
  log "wrote $STACK/.env"
else
  log "$STACK/.env exists"
fi

# init.sql
if [[ ! -f "$SCRIPTS/init.sql" ]]; then
  cat >"$SCRIPTS/init.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='failure_type_enum') THEN
    CREATE TYPE failure_type_enum AS ENUM ('UNKNOWN_ALGORITHM','MISSING_KEYS','CORRUPTED_DATA','CUSTOM_PROTECTION','VERSION_NOT_SUPPORTED','INSUFFICIENT_RESOURCES');
  END IF;
END $$;
CREATE TABLE IF NOT EXISTS cases(
  case_id TEXT PRIMARY KEY,
  case_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN',
  owner TEXT NOT NULL,
  risk_score NUMERIC(5,2) DEFAULT 0.0,
  risk_level TEXT DEFAULT 'LOW',
  created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS ingest_events(
  job_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id TEXT NOT NULL REFERENCES cases(case_id),
  object_key TEXT NOT NULL,
  sha256 VARCHAR(64) NOT NULL UNIQUE,
  created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS scan_results(
  job_id UUID REFERENCES ingest_events(job_id),
  case_id TEXT NOT NULL REFERENCES cases(case_id),
  family TEXT NOT NULL,
  score INTEGER NOT NULL DEFAULT 0,
  meta_json JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY(job_id, family)
);
CREATE TABLE IF NOT EXISTS timeline_events(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id TEXT NOT NULL REFERENCES cases(case_id),
  timestamp TIMESTAMPTZ NOT NULL,
  description TEXT,
  source TEXT,
  meta JSONB DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS decryption_failures(
  failure_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id TEXT NOT NULL REFERENCES cases(case_id),
  file_hash TEXT,
  failure_type failure_type_enum,
  error_message TEXT,
  failure_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO cases (case_id, case_name, owner)
VALUES ('DEMO_CASE_001','Initial Integrity Check','System')
ON CONFLICT (case_id) DO NOTHING;
SQL
fi
