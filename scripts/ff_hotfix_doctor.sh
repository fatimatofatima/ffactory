#!/usr/bin/env bash
set -Eeuo pipefail
LIB=/opt/ffactory/scripts/ff_lib.sh
DOC=/opt/ffactory/scripts/ff_doctor.sh
STACK=/opt/ffactory/stack
ENV_FILE="$STACK/.env"

cp -a "$LIB" "${LIB}.bak.$(date +%s)"
cp -a "$DOC" "${DOC}.bak.$(date +%s)"

# أ) أضف dc() = docker compose ثابت على مشروع ffactory
grep -qE '^dc\(\)' "$LIB" || cat >> "$LIB" <<'EOF'

# --- Compose helper (bind to the real project) ---
dc() {
  docker compose --project-name ffactory \
                --project-directory "$STACK" \
                --env-file "$ENV_FILE" \
                "$@"
}
EOF

# ب) خلّي الطبيب يستخدم dc بدل "docker compose"
sed -i 's/docker compose/dc/g' "$DOC"

# ج) اكتشاف خدمات من config --services بدل ps --services
sed -i 's/ps --services/config --services/g' "$DOC"
