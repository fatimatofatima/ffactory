#!/usr/bin/env bash
set -Eeuo pipefail

# 1) حل تعارض الأيتام في سكربتَي doctor/crash
patch_orphans() {
  for f in /opt/ffactory/scripts/ff_doctor_enhanced.sh /opt/ffactory/scripts/ff_crash_diagnostic.sh; do
    [ -f "$f" ] || continue
    grep -q 'unset COMPOSE_IGNORE_ORPHANS' "$f" || sed -i '1iunset COMPOSE_IGNORE_ORPHANS' "$f"
    sed -i -E 's/docker compose (.*) up -d --remove-orphans/COMPOSE_IGNORE_ORPHANS=0 docker compose \1 up -d --remove-orphans/g' "$f" || true
    sed -i -E 's/docker compose (.*) down --remove-orphans/COMPOSE_IGNORE_ORPHANS=0 docker compose \1 down --remove-orphans/g' "$f" || true
    chmod +x "$f"
  done
}

# 2) إضافة دوال المساعدة إن كانت مفقودة
patch_header() {
  local f=/opt/ffactory/scripts/ff_crash_diagnostic.sh
  [ -f "$f" ] || return 0
  grep -qE '(^|[^a-zA-Z0-9_])die\(\)' "$f" && return 0
  tmp=$(mktemp)
  cat >"$tmp"<<'HDR'
log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }
HDR
  cat "$f" >>"$tmp"
  mv "$tmp" "$f"
  chmod +x "$f"
}

# 3) Nginx: خيار هوست سريع. إن وُجد Nginx على الهوست أنشئ بلوك وكفايته
patch_nginx_host_proxy() {
  if command -v nginx >/dev/null; then
    tee /etc/nginx/conf.d/ff-healthd.conf >/dev/null <<'CONF'
location /__healthz      { proxy_pass http://127.0.0.1:9191/healthz; }
location /__health_report{ proxy_pass http://127.0.0.1:9191/report.html; }
CONF
    nginx -t && systemctl reload nginx || true
  fi
}

# توسيع bind للـ healthd ليسمع لكل الواجهات إذا رغبت بالوصول من الحاويات
sed -i 's/("127\.0\.0\.1", 9191)/("0.0.0.0", 9191)/' /opt/ffactory/scripts/ff_healthd.py || true
systemctl restart ff-healthd || true

patch_orphans
patch_header
patch_nginx_host_proxy
echo "ff_patch_helpers: done"
