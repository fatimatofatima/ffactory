#!/usr/bin/env bash
set -Eeuo pipefail
say(){ echo "[ff] $*"; } ; die(){ echo "[err] $*" >&2; exit 1; }

PW="Aa100200@@"
CN="ffactory_db"
VOL_DEFAULT="ffactory_postgres_data"
NET_DEFAULT="ffactory_ffactory_net"

# اكتشاف الصورة والڤوليوم
IMG="$(docker inspect -f '{{.Config.Image}}' "$CN" 2>/dev/null || echo 'postgres:16')"
VOL="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$CN" 2>/dev/null || true)"
[ -n "$VOL" ] || VOL="$VOL_DEFAULT"
docker volume inspect "$VOL" >/dev/null 2>&1 || docker volume create "$VOL" >/dev/null

# الشبكة + alias "db"
NET_NAME="$NET_DEFAULT"
docker network inspect "$NET_NAME" >/dev/null 2>&1 || docker network create "$NET_NAME" >/dev/null

say "image=$IMG volume=$VOL net=$NET_NAME"

# إيقاف وإزالة الحاوية لفتح الكلاستر
docker rm -f "$CN" >/dev/null 2>&1 || true

# تحديد نسخة PG من الڤوليوم
PGVER=$(docker run --rm -v "$VOL":/var/lib/postgresql/data busybox sh -lc 'cat /var/lib/postgresql/data/PG_VERSION 2>/dev/null || true')
case "$PGVER" in
  1[3-6]) SU_IMG="postgres:$PGVER" ;;
  *)      SU_IMG="$IMG" ;;
esac
say "single-user image=$SU_IMG (PG_VERSION=$PGVER)"

# حقن SQL من داخل الحاوية بنمط single-user عبر heredoc داخلي
docker run --rm -u postgres -v "$VOL":/var/lib/postgresql/data "$SU_IMG" bash -lc '
  set -e
  PGDATA=${PGDATA:-/var/lib/postgresql/data}
  PGBIN="$(command -v postgres)"
  [ -x "$PGBIN" ] || { echo "[err] postgres binary not found"; exit 1; }
  cat >/tmp/fix.sql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=''postgres'') THEN
    CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD '''"$PW"''';
  ELSE
    ALTER ROLE postgres WITH SUPERUSER PASSWORD '''"$PW"''';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=''ffadmin'') THEN
    CREATE ROLE ffadmin WITH LOGIN SUPERUSER PASSWORD '''"$PW"''';
  ELSE
    ALTER ROLE ffadmin WITH SUPERUSER PASSWORD '''"$PW"''';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=''ffactory'') THEN
    CREATE DATABASE ffactory OWNER ffadmin;
  END IF;
END
\$\$;
SQL
  "$PGBIN" --single -D "$PGDATA" postgres < /tmp/fix.sql
'

# تشغيل DB على الشبكة فقط مع healthcheck يعتمد psql
say "start db container with healthcheck"
docker run -d --name "$CN" \
  --network "$NET_NAME" --network-alias db \
  -e POSTGRES_PASSWORD="$PW" -e PGPASSWORD="$PW" \
  -v "$VOL":/var/lib/postgresql/data \
  --health-cmd='psql -h 127.0.0.1 -U ffadmin -d ffactory -c "SELECT 1" >/dev/null 2>&1 || exit 1' \
  --health-interval=5s --health-timeout=3s --health-retries=10 --health-start-period=5s \
  "$IMG" >/dev/null

# انتظار الصحة
for i in $(seq 1 60); do
  st=$(docker inspect -f "{{.State.Health.Status}}" "$CN" 2>/dev/null || echo "starting")
  [ "$st" = "healthy" ] && break
  sleep 1
  [ "$i" -eq 60 ] && die "db still not healthy"
done

# فحص اتصال فعلي
docker exec "$CN" psql -h 127.0.0.1 -U ffadmin -d ffactory -c "SELECT current_user, current_database();" >/dev/null

say "OK: ffadmin/ffactory جاهزان. كلمة السر مضبوطة."
say "اتصال الخدمات داخل الشبكة: host=db, port=5432, user=ffadmin, db=ffactory, password=$PW"
