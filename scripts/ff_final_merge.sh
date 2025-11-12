#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[ff] %s\n" "$*"; }
warn(){ printf "[warn] %s\n" "$*" >&2; }
die(){ printf "[err] %s\n" "$*" >&2; exit 1; }

FF=/opt/ffactory
STACK=$FF/stack
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
NET="${PROJECT}_ffactory_net"

# --- ثوابت DB ---
export POSTGRES_USER="ffadmin"
export POSTGRES_DB="ffactory"
export POSTGRES_PASSWORD="Aa100200@@"
DB_CN=ffactory_db
DATA_VOL=ffactory_postgres_data

install -d -m 755 "$STACK"

# شبكة المشروع
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# Compose مصغّر للـ db فقط (بلا منافذ مضيف)
IMG="$(docker inspect -f '{{.Config.Image}}' "$DB_CN" 2>/dev/null || echo postgres:16)"
docker volume inspect "$DATA_VOL" >/dev/null 2>&1 || docker volume create "$DATA_VOL" >/dev/null

cat >"$STACK/docker-compose.db-core.yml" <<YML
services:
  db:
    image: ${IMG}
    container_name: ${DB_CN}
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
    healthcheck:
      test: ["CMD-SHELL","pg_isready -h 127.0.0.1 -p 5432"]
      interval: 5s
      timeout: 3s
      retries: 60
    volumes:
      - ${DATA_VOL}:/var/lib/postgresql/data
    networks: [ ffactory_net ]
networks:
  ffactory_net: { external: true, name: ${NET} }
volumes:
  ${DATA_VOL}: { external: true, name: ${DATA_VOL} }
YML

log "Up db بدون منافذ مضيف"
docker rm -f "$DB_CN" >/dev/null 2>&1 || true
docker compose -p "$PROJECT" -f "$STACK/docker-compose.db-core.yml" up -d db

# مسارات PostgreSQL داخل الحاوية
PGDATA=$(docker exec -u postgres "$DB_CN" bash -lc 'echo "${PGDATA:-/var/lib/postgresql/data}"')
[ -n "$PGDATA" ] || die "PGDATA غير معروف"
PG_BIN=$(docker exec -u postgres "$DB_CN" bash -lc 'dirname "$(command -v pg_ctl)"')
[ -n "$PG_BIN" ] || die "pg_ctl غير موجود"

# إيقاف الخادم وتشغيل single-user لإجبار إنشاء/تعديل الأدوار والقاعدة
log "تصحيح الأدوار وقاعدة ffactory بنمط single-user"
docker exec -u postgres "$DB_CN" bash -lc "$PG_BIN/pg_ctl -D '$PGDATA' -m fast stop"
cat >"$STACK/_fix.sql" <<SQL
DO \$\$
BEGIN
  -- superuser postgres
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='postgres') THEN
    EXECUTE $$CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD '${POSTGRES_PASSWORD}'$$;
  ELSE
    EXECUTE $$ALTER ROLE postgres WITH PASSWORD '${POSTGRES_PASSWORD}'$$;
  END IF;

  -- superuser ffadmin
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}') THEN
    EXECUTE $$CREATE ROLE ${POSTGRES_USER} WITH LOGIN SUPERUSER PASSWORD '${POSTGRES_PASSWORD}'$$;
  ELSE
    EXECUTE $$ALTER ROLE ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}'$$;
  END IF;

  -- قاعدة ffactory
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}') THEN
    EXECUTE $$CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER}$$;
  END IF;
END
\$\$;
SQL
docker exec -u postgres -i "$DB_CN" bash -lc "$PG_BIN/postgres --single -D '$PGDATA' postgres" < "$STACK/_fix.sql" >/dev/null
docker exec -u postgres "$DB_CN" bash -lc "$PG_BIN/pg_ctl -D '$PGDATA' -w start"

# انتظار الجاهزية عبر الشبكة الداخلية
log "انتظار جاهزية db"
for i in {1..60}; do
  docker run --rm --network "$NET" -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres:16 \
    pg_isready -h db -p 5432 -U ${POSTGRES_USER} >/dev/null 2>&1 && break
  sleep 1
  [ "$i" -eq 60 ] && die "db لم يصبح جاهزاً"
done

# فحص اتصال وجدول probe
docker run --rm --network "$NET" -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres:16 \
  psql -v ON_ERROR_STOP=1 -h db -U ${POSTGRES_USER} -d ${POSTGRES_DB} \
  -c "CREATE TABLE IF NOT EXISTS _probe(x int);
      INSERT INTO _probe VALUES (1) ON CONFLICT DO NOTHING;
      SELECT count(*) FROM _probe;" >/dev/null || true

# Overrides لبيئات DB/Neo4j والاعتماد على الصحة
cat >"$STACK/docker-compose.db-env.yml" <<YML
services:
  api_gateway:          { environment: { DB_HOST: db, DB_PORT: "5432", DB_USER: "${POSTGRES_USER}", DB_PASSWORD: "${POSTGRES_PASSWORD}", DB_NAME: "${POSTGRES_DB}" } }
  investigation_api:    { environment: { DB_HOST: db, DB_PORT: "5432", DB_USER: "${POSTGRES_USER}", DB_PASSWORD: "${POSTGRES_PASSWORD}", DB_NAME: "${POSTGRES_DB}" } }
  correlation_engine:   { environment: { DB_HOST: db, DB_PORT: "5432", DB_USER: "${POSTGRES_USER}", DB_PASSWORD: "${POSTGRES_PASSWORD}", DB_NAME: "${POSTGRES_DB}" } }
  behavioral_analytics: { environment: { DB_HOST: db, DB_PORT: "5432", DB_USER: "${POSTGRES_USER}", DB_PASSWORD: "${POSTGRES_PASSWORD}", DB_NAME: "${POSTGRES_DB}" } }
YML

cat >"$STACK/docker-compose.neo4j-env.yml" <<'YML'
services:
  api_gateway:        { environment: { NEO4J_HOST: neo4j, NEO4J_PORT: "7687" } }
  investigation_api:  { environment: { NEO4J_HOST: neo4j, NEO4J_PORT: "7687" } }
  correlation_engine: { environment: { NEO4J_HOST: neo4j, NEO4J_PORT: "7687" } }
YML

cat >"$STACK/docker-compose.depends.yml" <<'YML'
services:
  api_gateway:        { depends_on: { db: { condition: service_healthy }, neo4j: { condition: service_healthy } } }
  investigation_api:  { depends_on: { db: { condition: service_healthy }, neo4j: { condition: service_healthy } } }
  correlation_engine: { depends_on: { db: { condition: service_healthy }, neo4j: { condition: service_healthy } } }
  behavioral_analytics:{ depends_on: { db: { condition: service_healthy } } }
YML

# اختيار ملف compose الأساس المتاح
BASE=""
for f in docker-compose.yml docker-compose.ultimate.yml docker-compose.obsv.yml; do
  [ -f "$STACK/$f" ] && BASE="$STACK/$f" && break
done

if [ -n "$BASE" ]; then
  log "تشغيل الخدمات الأساسية بأوفرايد البيئة"
  EXTRAS=()
  [ -f "$STACK/docker-compose.health.yml" ] && EXTRAS+=(-f "$STACK/docker-compose.health.yml")
  EXTRAS+=(-f "$STACK/docker-compose.depends.yml" -f "$STACK/docker-compose.db-env.yml" -f "$STACK/docker-compose.neo4j-env.yml")
  docker compose -p "$PROJECT" -f "$BASE" "${EXTRAS[@]}" up -d api_gateway investigation_api correlation_engine
else
  warn "لا يوجد base compose تحت $STACK. تم تجهيز db فقط."
fi

# تحقق نهائي داخل الشبكة
docker run --rm --network "$NET" -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres:16 \
  psql -h db -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "SELECT current_user, current_database();" || true

log "تم."
