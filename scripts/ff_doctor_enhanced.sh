#!/usr/bin/env bash
set -Eeuo pipefail
LOG="/opt/ffactory/logs/doctor_$(date +%F).log"
echo "[$(date '+%F %T')] start" | tee -a "$LOG"
systemctl is-active sf-factory.service >>"$LOG" 2>&1 || true
if command -v docker >/dev/null 2>&1; then docker info >/dev/null 2>&1 && echo "docker: ok" >>"$LOG" || echo "docker: not ready" >>"$LOG"; fi
echo "[$(date '+%F %T')] end" | tee -a "$LOG"
exit 0
