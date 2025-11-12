#!/usr/bin/env bash
# لا يخرج من الشيل لو حصلت أخطاء
set +e
export LC_ALL=C

cd /opt/ffactory/stack || { echo "✗ stack dir missing"; exit 0; }
sed -i 's/\xC2\xA0/ /g' *.yml 2>/dev/null

echo "[1/3] compose config (بدون override) ..."
docker compose -p ffactory \
  -f stack.yml -f apis.yml -f analytics.yml -f ui.yml \
  --env-file .env \
  config >/tmp/ffactory_compose.base.yaml 2>/tmp/ffactory_compose.base.err
BASE_RC=$?
if [ $BASE_RC -ne 0 ]; then
  echo "CONFIG ERROR (base files):"
  sed -n '1,200p' /tmp/ffactory_compose.base.err
fi

echo "[2/3] compose config (مع override) ..."
docker compose -p ffactory \
  -f stack.yml -f apis.yml -f analytics.yml -f ui.yml -f override.yml \
  --env-file .env \
  config >/tmp/ffactory_compose.full.yaml 2>/tmp/ffactory_compose.full.err
FULL_RC=$?
if [ $FULL_RC -ne 0 ]; then
  echo "CONFIG ERROR (with override.yml):"
  sed -n '1,200p' /tmp/ffactory_compose.full.err
fi

if [ $BASE_RC -eq 0 ] && [ $FULL_RC -eq 0 ]; then
  echo "[3/3] docker compose up ..."
  docker compose -p ffactory \
    -f stack.yml -f apis.yml -f analytics.yml -f ui.yml -f override.yml \
    --env-file .env \
    up -d --build --remove-orphans || echo "✗ up failed (لكن الشيل مكمل)"
else
  echo "لن نشغّل up لأن config فيه أخطاء."
fi

echo "تم — السكربت انتهى بدون exit قاسٍ."
