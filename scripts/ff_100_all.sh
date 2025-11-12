#!/usr/bin/env bash
set -Eeuo pipefail

/opt/ffactory/scripts/ff_00_env.sh
/opt/ffactory/scripts/ff_10_clean.sh     # يمسح كل ffactory_* قديم
/opt/ffactory/scripts/ff_20_core_up.sh   # يشغّل core
/opt/ffactory/scripts/ff_30_apps_up.sh   # يشغّل apps لو موجودة
/opt/ffactory/scripts/ff_40_ai_echo.sh   # يشغّل خدمات AI على البورتات
/opt/ffactory/scripts/ff_50_health_fix.sh
/opt/ffactory/scripts/ff_90_verify.sh

echo
echo "🎉 FFactory 100% up ✅"
