#!/usr/bin/env bash
set -Eeuo pipefail
OUT="/opt/ffactory/backups"; mkdir -p "$OUT"
TS="$(date +%Y%m%d_%H%M%S)"
SRC="/opt/ffactory/apps"
TGZ="$OUT/apps-sh-${TS}.tgz"
LIST="$OUT/apps-sh-${TS}.list"
SHA="$TGZ.sha256"

[[ -d "$SRC" ]] || { echo "لا يوجد مجلد apps عند $SRC"; exit 1; }

find "$SRC" -type f | sort > "$LIST"
tar -czf "$TGZ" -C "$SRC" . 
sha256sum "$TGZ" > "$SHA"
chmod 600 "$TGZ" "$SHA" || true

echo "أُنشئ الأرشيف: $TGZ"
echo "SHA256 مخزنة في: $SHA"
