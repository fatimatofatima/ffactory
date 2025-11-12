#!/usr/bin/env bash
# FFactory Postgres Setup: Fixes authentication issues by temporarily using "trust" mode.
set -Eeuo pipefail

log(){ echo "🟢 $*"; }
warn(){ echo "🟡 $*" >&2; }
die(){ echo "🔴 $*" >&2; exit 1; }

FF=/opt/ffactory
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
NET="${PROJECT}_ffactory_net"
DB_CN=ffactory_db

# --- ثوابت ---
export PGPASSWORD="Aa100200@@"
export POSTGRES_USER="ffadmin"
export POSTGRES_DB="ffactory"
# المستخدم الذي سيستخدمه Docker للوصول الأولي
ROOT_USER="postgres"

# تحقق من أن الحاوية قيد التشغيل أولاً
docker inspect "$DB_CN" >/dev/null 2>&1 || die "الحاوية $DB_CN ليست قيد التشغيل. شغّل db أولاً."

# 1. الدخول وتعديل pg_hba.conf إلى 'trust' (الثقة التامة)
log "1/4. تعديل pg_hba.conf إلى 'trust' للسماح بالوصول المحلي بلا كلمة سر"
# نستخدم pg_hba.conf.bak كنسخة احتياطية
docker exec -u root "$DB_CN" bash -c "
  # تأكيد مسار البيانات (PGDATA)
  PGDATA=\$(find / -name 'base' -type d 2>/dev/null | sed 's#/base$##' | head -n1 || echo '/var/lib/postgresql/data')
  cp \"\$PGDATA/pg_hba.conf\" \"\$PGDATA/pg_hba.conf.bak\"
  # استخدام awk لاستبدال طريقة المصادقة (e.g., md5, scram-sha-256) بـ trust
  awk '
    # استبدل المصادقة لجميع المستخدمين الذين يتصلون عبر الشبكة الداخلية (host/local) بـ trust
    /host|local/ {
        if(\$NF !~ /^trust$/) {
            NF = NF
            \$NF = \"trust\"
        }
    }
    1
  ' \"\$PGDATA/pg_hba.conf.bak\" > \"\$PGDATA/pg_hba.conf\"
"

# 2. إعادة تحميل تهيئة Postgres
log "2/4. إعادة تحميل تهيئة Postgres لتطبيق 'trust' (تجنب إعادة التشغيل)"
docker exec -u root "$DB_CN" pg_ctl reload || warn "pg_ctl reload فشل. ربما pg_ctl ليس في المسار. سنتجاوز."

# 3. إنشاء المستخدم والقاعدة بشكل آمن باستخدام الاتصال الموثوق
log "3/4. إنشاء الدور ffadmin والقاعدة ffactory"
docker run --rm --network "$NET" -e PGUSER="$ROOT_USER" postgres:16 \
  psql -h db -v ON_ERROR_STOP=1 -U "$ROOT_USER" <<SQL || die "فشل إنشاء الدور والقاعدة."
DO \$\$
BEGIN
  -- 1. إنشاء ffadmin
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}') THEN
    EXECUTE $$CREATE ROLE ${POSTGRES_USER} LOGIN PASSWORD '${PGPASSWORD}'$$;
  ELSE
    EXECUTE $$ALTER ROLE ${POSTGRES_USER} WITH PASSWORD '${PGPASSWORD}'$$;
  END IF;

  -- 2. إنشاء قاعدة البيانات
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}') THEN
    EXECUTE $$CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER}$$;
  END IF;
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};
SQL

# 4. إعادة pg_hba.conf إلى الوضع الآمن الأصلي
log "4/4. إعادة pg_hba.conf إلى الوضع الأصلي وإعادة تحميل التهيئة"
docker exec -u root "$DB_CN" bash -c "
  PGDATA=\$(find / -name 'base' -type d 2>/dev/null | sed 's#/base$##' | head -n1 || echo '/var/lib/postgresql/data')
  mv \"\$PGDATA/pg_hba.conf.bak\" \"\$PGDATA/pg_hba.conf\"
  pg_ctl reload || true
"

# --- فحص نهائي ---
log "✅ تم تهيئة Postgres بنجاح."
docker run --rm --network "$NET" -e PGPASSWORD="$PGPASSWORD" postgres:16 \
  psql -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 'SUCCESS: Database and User Ready' AS status;"

log "الآن، شغّل الخدمات التابعة مجدداً."
