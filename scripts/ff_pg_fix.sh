#!/usr/bin/env bash
set -Eeuo pipefail
say(){ echo "[ff] $*"; } ; die(){ echo "[err] $*" >&2; exit 1; }

PW="Aa100200@@"                       # كلمة السر المطلوبة
CN="ffactory_db"                      # اسم الحاوية
VOL_DEFAULT="ffactory_postgres_data"  # اسم الڤوليوم الافتراضي
NET_DEFAULT="ffactory_ffactory_net"   # اسم الشبكة الافتراضي

# 0) اكتشاف الصورة والڤوليوم والشبكة الحالية إن وجدت
IMG="$(docker inspect -f '{{.Config.Image}}' "$CN" 2>/dev/null || echo 'postgres:16')"
VOL="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$CN" 2>/dev/null || true)"
[ -n "$VOL" ] || VOL="$VOL_DEFAULT"

# الشبكة
if docker inspect "$CN" >/dev/null 2>&1; then
  NET="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$CN" 2>/dev/null || true)"
  # إن لم نجد اسم الشبكة عبر ID، استخدم الافتراضي
  NET_NAME="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$CN" 2>/dev/null || echo "$NET_DEFAULT")"
else
  NET_NAME="$NET_DEFAULT"
fi
docker network inspect "$NET_NAME" >/dev/null 2>&1 || docker network create "$NET_NAME" >/dev/null

say "استخدام الصورة: $IMG"
say "الڤوليوم: $VOL"
say "الشبكة: $NET_NAME"

# 1) إيقاف وإزالة حاوية DB لتفادي قفل الملفات
docker rm -f "$CN" >/dev/null 2>&1 || true

# 2) تحديد إصدار PG من داخل الڤوليوم واختيار صورة مطابقة للـ single-user
PGVER=$(docker run --rm -v "$VOL":/var/lib/postgresql/data busybox sh -lc 'cat /var/lib/postgresql/data/PG_VERSION 2>/dev/null || true')
case "$PGVER" in
  1[3-6]) SU_IMG="postgres:$PGVER" ;;
  *)      SU_IMG="$IMG" ;;
esac
say "صورة single-user: $SU_IMG (PG_VERSION=$PGVER)"

# 3) تعديل الكتالوج بنمط single-user: فرض وجود/تعديل أدوار وكلمة السر وقاعدة ffactory
SQL_FIX=$(cat <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='postgres') THEN
    EXECUTE $$CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'PW_PLACEHOLDER'$$;
  ELSE
    EXECUTE $$ALTER ROLE postgres WITH SUPERUSER PASSWORD 'PW_PLACEHOLDER'$$;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ffadmin') THEN
    EXECUTE $$CREATE ROLE ffadmin WITH LOGIN SUPERUSER PASSWORD 'PW_PLACEHOLDER'$$;
  ELSE
    EXECUTE $$ALTER ROLE ffadmin WITH SUPERUSER PASSWORD 'PW_PLACEHOLDER'$$;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='ffactory') THEN
    EXECUTE $$CREATE DATABASE ffactory OWNER ffadmin$$;
  END IF;
END $$;
SQL
)
SQL_FIX="${SQL_FIX//PW_PLACEHOLDER/$PW}"

say "تشغيل postgres --single لتعديل الأدوار والقاعدة"
echo "$SQL_FIX" | docker run --rm -i \
  -u postgres \
  -v "$VOL":/var/lib/postgresql/data \
  "$SU_IMG" bash -lc '
    set -e
    PGDATA=${PGDATA:-/var/lib/postgresql/data}
    # استخدام المسار المطلق لتفادي PATH
    if [ -x /usr/local/bin/postgres ]; then PGBIN=/usr/local/bin;
    elif [ -x /usr/lib/postgresql/16/bin/postgres ]; then PGBIN=/usr/lib/postgresql/16/bin;
    elif [ -x /usr/lib/postgresql/15/bin/postgres ]; then PGBIN=/usr/lib/postgresql/15/bin;
    else PGBIN=""; fi
    [ -n "$PGBIN" ] || { echo "[err] لم أجد postgres binary"; exit 1; }
    "$PGBIN/postgres" --single -D "$PGDATA" postgres >/dev/null
  '

# 4) إعادة تشغيل حاوية DB على الشبكة الداخلية فقط (بلا نشر منافذ مضيف)
say "تشغيل حاوية DB"
docker run -d --name "$CN" \
  --network "$NET_NAME" \
  -e POSTGRES_PASSWORD="$PW" \
  -v "$VOL":/var/lib/postgresql/data \
  "$IMG" >/dev/null

# 5) انتظار الجاهزية من داخل الحاوية
say "انتظار جاهزية pg_isready"
for i in $(seq 1 60); do
  if docker exec "$CN" bash -lc '
      if command -v pg_isready >/dev/null 2>&1; then pg_isready -h 127.0.0.1 -p 5432 -U ffadmin >/dev/null 2>&1; else exit 1; fi
    '; then
    break
  fi
  sleep 1
  [ "$i" -eq 60 ] && die "Postgres لم يصبح جاهزاً"
done

# 6) فحص اتصال فعلي وإنشاء probe
say "فحص اتصال ffadmin@ffactory"
docker exec "$CN" bash -lc 'psql -v ON_ERROR_STOP=1 -U ffadmin -d ffactory -h 127.0.0.1 -c "CREATE TABLE IF NOT EXISTS _probe(x int); INSERT INTO _probe VALUES (1) ON CONFLICT DO NOTHING; SELECT count(*) FROM _probe;"' >/dev/null

say "تم إصلاح DB وكلمة السر ثابتة"
say "بيانات الاتصال داخل الشبكة: host=db أو ffactory_db, port=5432, user=ffadmin, db=ffactory, password='"$PW"'"
