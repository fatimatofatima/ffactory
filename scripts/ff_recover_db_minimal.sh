#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[+] $*"; } ; die(){ echo "[x] $*" >&2; exit 1; }

STACK=/opt/ffactory/stack
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
NET_NAME=${PROJECT}_ffactory_net
VOL_NAME=ffactory_postgres_data
CN=ffactory_db

install -d -m 755 "$STACK"

# استخرج صورة db وڤوليوم البيانات وكلمة السر إن وُجدت
IMG=$(docker inspect -f '{{.Config.Image}}' "$CN" 2>/dev/null || echo 'postgres:16')
DATA_VOL=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$CN" 2>/dev/null || true)
[ -n "$DATA_VOL" ] || DATA_VOL="$VOL_NAME"

PGPW=$(docker inspect "$CN" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^POSTGRES_PASSWORD=\(.*\)$/\1/p' | tail -n1)
# ملاحظة: لو الكلاستر مُهيأ سابقًا فـ POSTGRES_PASSWORD لا يغيّر الواقع، سنحاول استخدامه للاتصال فقط.

# تحقق من الشبكة والڤوليوم
docker network inspect "$NET_NAME" >/dev/null 2>&1 || die "شبكة $NET_NAME غير موجودة"
docker volume inspect "$DATA_VOL"  >/dev/null 2>&1 || docker volume create "$DATA_VOL" >/dev/null

# اكتب compose أساسي لـ db فقط، بلا نشر منافذ
tee "$STACK/docker-compose.yml" >/dev/null <<YML
services:
  db:
    image: ${IMG}
    container_name: ${CN}
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: "${PGPW}"
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U postgres -h 127.0.0.1 -p 5432"]
      interval: 5s
      timeout: 3s
      retries: 20
    volumes:
      - ${DATA_VOL}:/var/lib/postgresql/data
    networks: [ ffactory_net ]

networks:
  ffactory_net:
    external: true
    name: ${NET_NAME}

volumes:
  ${DATA_VOL}:
    external: true
    name: ${DATA_VOL}
YML

# أزِل الحاوية الحالية لو موجودة ثم ارفع db
docker rm -f "$CN" >/dev/null 2>&1 || true
docker compose -p "$PROJECT" -f "$STACK/docker-compose.yml" up -d db

# انتظر الصحة
for i in {1..60}; do
  st=$(docker inspect -f '{{.State.Health.Status}}' "$CN" 2>/dev/null || echo "starting")
  [ "$st" = "healthy" ] && { log "db healthy"; break; }
  sleep 2
done
[ "$st" = "healthy" ] || { docker logs "$CN" | tail -n 100 >&2; die "db لم يصبح healthy"; }

# خزّن كلمة السر المُكتشفة لخطوة الإنشاء التالية
if [ -n "$PGPW" ]; then
  echo "$PGPW" > /opt/ffactory/.pgpw  # للاستخدام المؤقت
fi
log "compose الأساسي لـ db جاهز في $STACK/docker-compose.yml"
