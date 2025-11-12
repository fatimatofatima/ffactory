#!/usr/bin/env bash
set -Eeuo pipefail

# ===== إعدادات =====
PREFIX="ffactory_"
PORTS="8081 8082 8083 8086 8000 8170 8088 5433 6379 7474 9000 9001"
LOG="/opt/ffactory/logs/ff_power_check.$(date +%F_%H%M%S).log"
mkdir -p /opt/ffactory/logs

ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*" | tee -a "$LOG"; }

log "🚀 FFactory POWER CHECK"

# ===== 1) ملخّص السيرفر =====
MEM_TOT=$(grep MemTotal /proc/meminfo | awk '{print $2/1024 " MB"}')
MEM_FREE=$(grep MemAvailable /proc/meminfo | awk '{print $2/1024 " MB"}')
LOAD=$(cat /proc/loadavg | awk '{print $1,$2,$3}')
CPU=$(nproc)

log "🖥  النظام:"
log "   🔹 CPU: $CPU cores"
log "   🔹 RAM total: $MEM_TOT"
log "   🔹 RAM avail: $MEM_FREE"
log "   🔹 Load: $LOAD"

# ===== 2) الحاويات =====
log ""
log "🐳 حاويات FFactory:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$PREFIX" | tee -a "$LOG" || log "لا يوجد حاويات تبدأ بـ $PREFIX"

# ===== 3) فحص المنافذ =====
log ""
log "🔌 فحص المنافذ:"
for p in $PORTS; do
  if nc -z 127.0.0.1 "$p" 2>/dev/null; then
    log "   ✅ port $p مفتوح"
  else
    log "   ❌ port $p مغلق"
  fi
done

# ===== 4) فحص /health لو موجود =====
log ""
log "🩺 فحص health endpoints (اختياري):"
for p in 8081 8082 8083 8086 8000 8170 8088; do
  NAME=""
  case $p in
    8081) NAME=vision ;;
    8082) NAME=media_forensics ;;
    8083) NAME=hashset ;;
    8086) NAME=asr ;;
    8000) NAME=nlp ;;
    8170) NAME=correlation ;;
    8088) NAME=social ;;
  esac

  if curl -fs "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
    log "   ✅ $NAME على /health"
  else
    # جرب الجذر /
    if curl -fs "http://127.0.0.1:$p/" >/dev/null 2>&1; then
      log "   ⚠️  $NAME شغّال بس مافيش /health (استعمل / )"
    else
      log "   ❌ $NAME ما بيرد"
    fi
  fi
done

# ===== 5) اكتشاف الكونفلكت =====
log ""
log "🧱 فحص تعارض أسماء الحاويات:"
CONFLICTS=$(docker ps -a --format '{{.Names}}' | grep '^ffactory_' | sort)
echo "$CONFLICTS" | tee -a "$LOG" >/dev/null
# مفيش منطقياً تعارض دلوقتي، بس لو عملت compose وهو شغّال يحصل

log ""
log "📦 لو شغّلت docker compose وهو عندك الحاويات دي شغّالة، docker هيقولك: Conflict. الحل إنك تعمل:"
log "   docker stop ffactory_db ffactory_redis ffactory_minio ffactory_neo4j || true"
log "   docker rm   ffactory_db ffactory_redis ffactory_minio ffactory_neo4j || true"
log "   ثم تعيد docker compose up -d"

log ""
log "✅ القياس خلص. اللوج: $LOG"
