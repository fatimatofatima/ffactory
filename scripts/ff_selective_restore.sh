#!/usr/bin/env bash
set -Eeuo pipefail

MEMORY_FILE="/opt/ffactory/system_memory.json"
BASE_DIR="/opt/ffactory"
STACK_CORE="$BASE_DIR/stack/docker-compose.core.yml"
STACK_APPS="$BASE_DIR/stack/docker-compose.apps.yml"
STACK_OVERRIDE="$BASE_DIR/stack/docker-compose.override.yml"

# خدماتنا التقيلة اللي غالباً هنعالجها
DEFAULT_SERVICES=("ffactory_vision" "ffactory_media_forensics" "ffactory_hashset")

echo "📦 FFactory selective restore"
echo "============================"

bad_services=()

# 1) حاول تقرا الملف لو موجود
if [ -f "$MEMORY_FILE" ]; then
  echo "📖 بقرأ $MEMORY_FILE ..."
  # بنجيب still_bad لو موجود
  mapfile -t parsed < <(jq -r '.still_bad[]? // empty' "$MEMORY_FILE" 2>/dev/null || true)
  if [ "${#parsed[@]}" -gt 0 ]; then
    bad_services=("${parsed[@]}")
    echo "🟠 لقيت خدمات معلّمة still_bad في الـ JSON:"
    for s in "${bad_services[@]}"; do
      echo "   - $s"
    done
  else
    echo "ℹ️ الملف موجود بس مفيش still_bad."
  fi
else
  echo "⚠️ مفيش $MEMORY_FILE ، هنكمل تفاعلي."
fi

# 2) لو مفيش ولا خدمة في bad_services نديك اختيار
if [ "${#bad_services[@]}" -eq 0 ]; then
  echo
  echo "❔ تحب تعالج إيه؟"
  echo "  1) الخدمات التقيلة المعروفة (vision / media_forensics / hashset)"
  echo "  2) كل خدمات ffactory-* الشغالة دلوقتي (restart)"
  echo "  3) أكتبلي الأسماء بإيدك"
  echo "  4) خروج"
  read -rp "اختيارك [1-4]: " choice

  case "$choice" in
    1)
      bad_services=("${DEFAULT_SERVICES[@]}")
      ;;
    2)
      # نجيب كل الحاويات اللي اسمها ffactory_*
      mapfile -t running < <(docker ps --format '{{.Names}}' | grep '^ffactory_' || true)
      bad_services=("${running[@]}")
      ;;
    3)
      read -rp "اكتب أسماء الخدمات وبينهم مسافة: " line
      # shellcheck disable=SC2206
      bad_services=($line)
      ;;
    *)
      echo "🚪 خروج."
      exit 0
      ;;
  esac
fi

# 3) في اللحظة دي لازم يكون عندنا قائمة
if [ "${#bad_services[@]}" -eq 0 ]; then
  echo "❌ مفيش حاجة أعالجها."
  exit 0
fi

echo
echo "🔁 هتعامل مع الخدمات دي:"
for s in "${bad_services[@]}"; do
  echo "   - $s"
done
echo

cd "$BASE_DIR"

# 4) نحاول نرجّعهم
for svc in "${bad_services[@]}"; do
  echo "🩺 معالجة: $svc"

  # لو الاسم جاي من الـ JSON من غير prefix نضيفه
  if ! docker ps --format '{{.Names}}' | grep -qx "$svc"; then
    # جرّب بنفس الاسم من غير ffactory_
    if docker ps --format '{{.Names}}' | grep -qx "ffactory_$svc"; then
      svc="ffactory_$svc"
    fi
  fi

  if docker ps --format '{{.Names}}' | grep -qx "$svc"; then
    # موجود -> restart
    if docker restart "$svc" >/dev/null 2>&1; then
      echo "   ✅ restart done"
    else
      echo "   ⚠️ restart فشل، هجرّب compose up ..."
      docker compose -f "$STACK_CORE" -f "$STACK_APPS" -f "$STACK_OVERRIDE" up -d "$svc" || true
    fi
  else
    echo "   ⚠️ مش لاقي حاوية باسم $svc -> هعملها up"
    docker compose -f "$STACK_CORE" -f "$STACK_APPS" -f "$STACK_OVERRIDE" up -d "$svc" || true
  fi

  # 5) مراقبة بسيطة عشان "مايخرجش من الشيل" قبل ما يتأكد
  echo "   ⏳ مستني الخدمة تطلع..."
  ok=0
  for i in {1..15}; do
    status=$(docker ps --format '{{.Names}} {{.Status}}' | grep "$svc" || true)
    if echo "$status" | grep -qi "Up"; then
      echo "   ✅ الخدمة طلعت: $status"
      ok=1
      break
    fi
    sleep 2
  done
  if [ "$ok" -eq 0 ]; then
    echo "   ❗ لسه مش Up بعد الانتظار."
  fi
done

echo
echo "📋 حالة كل خدمات ffactory بعد الإصلاح:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep ffactory || true

echo "🎉 خلصنا."
