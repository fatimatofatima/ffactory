#!/usr/bin/env bash
set -Eeuo pipefail
say(){ echo "[ff] $*"; } ; die(){ echo "[err] $*" >&2; exit 1; }

PW="${PW:-Aa100200@@}"                 # كلمة السر المطلوبة
CN="${CN:-ffactory_db}"                # اسم الحاوية
VOL="${VOL:-ffactory_postgres_data}"   # اسم الڤوليوم
NET="${NET:-ffactory_ffactory_net}"    # اسم الشبكة
IMG="${IMG:-postgres:16}"              # صورة postgres

# 0) تجهيز شبكة وڤوليوم
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker volume inspect "$VOL" >/dev/null 2>&1 || docker volume create "$VOL" >/dev/null

# 1) أوقف الحاوية إن وُجدت
docker rm -f "$CN" >/dev/null 2>&1 || true

# 2) إصلاح الأدوار والقاعدة بنمط single-user بدون سيرفر
say "patch roles/db in single-user mode"
docker run --rm -u postgres -e PW="$PW" -v "$VOL":/var/lib/postgresql/data "$IMG" bash -lc '
  set -e
  PGDATA=${PGDATA:-/var/lib/postgresql/data}
  cat >/tmp/fix.sql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=''postgres'') THEN
    CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD ''__PW__'';
  ELSE
    ALTER ROLE postgres WITH SUPERUSER PASSWORD ''__PW__'';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=''ffadmin'') THEN
    CREATE ROLE ffadmin WITH LOGIN SUPERUSER PASSWORD ''__PW__'';
  ELSE
    ALTER ROLE ffadmin WITH SUPERUSER PASSWORD ''__PW__'';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=''ffactory'') THEN
    CREATE DATABASE ffactory OWNER ffadmin;
  END IF;
END
\$\$;
SQL
  sed -i "s/__PW__/${PW//\//\\/}/g" /tmp/fix.sql
  postgres --single -D "$PGDATA" postgres < /tmp/fix.sql
'

# 3) اختيار منفذ مضيف حر أو عدم النشر على المضيف
pick_port(){
  for p in 5433 5434 15432; do ss -ltnH "( sport = :$p )" | grep -q . || { echo "$p"; return; }; done
  echo ""
}
HP="$(pick_port)"
PORT_ARGS=()
[ -n "$HP" ] && PORT_ARGS=(-p "${HP}:5432") || say "no free host port, running without -p"

# 4) تشغيل الحاوية بصحة حقيقية و alias=db
say "start db container"
docker run -d --name "$CN" \
  --network "$NET" --network-alias db \
  -e POSTGRES_PASSWORD="$PW" \
  -v "$VOL":/var/lib/postgresql/data \
  "${PORT_ARGS[@]}" \
  --health-cmd="pg_isready -U ffadmin -d ffactory -h 127.0.0.1 >/dev/null 2>&1 || exit 1" \
  --health-interval=5s --health-timeout=3s --health-retries=20 --health-start-period=5s \
  "$IMG" >/dev/null

# 5) انتظار الصحة
for i in $(seq 1 120); do
  st=$(docker inspect -f "{{.State.Health.Status}}" "$CN" 2>/dev/null || echo "starting")
  [ "$st" = "healthy" ] && break
  sleep 1
  [ "$i" -eq 120 ] && die "db not healthy"
done

# 6) فحص اتصال فعلي عبر الشبكة الداخلية
docker run --rm --network "$NET" -e PGPASSWORD="$PW" "$IMG" \
  psql -h db -U ffadmin -d ffactory -c "SELECT current_user, current_database();" >/dev/null \
  || die "psql check failed"

# 7) طباعة ملخص وربط المضيف إن وُجد
say "OK. db=healthy user=ffadmin dbname=ffactory pw=$PW"
if [ -n "$HP" ]; then
  say "host port: $HP -> 5432"
else
  say "no host port bound. use internal dns: db:5432"
fi

# 8) إعادة تشغيل الخدمات التابعة إن كانت موجودة
for s in ffactory_api_gateway ffactory_investigation_api ffactory_correlation_engine ffactory_behavioral_analytics; do
  docker inspect "$s" >/dev/null 2>&1 && docker restart "$s" >/dev/null 2>&1 || true
done
