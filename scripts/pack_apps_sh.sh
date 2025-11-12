#!/usr/bin/env bash
set -Eeuo pipefail

SRC=${1:-/opt/ffactory/apps}
BACKUP_DIR=${BACKUP_DIR:-/opt/ffactory/backups}
TS=$(date +%F-%H%M%S)
OUT="$BACKUP_DIR/apps-sh-$TS.tgz"
SHA="$OUT.sha256"
LIST="$BACKUP_DIR/apps-sh-$TS.list"
TMP=$(mktemp)

log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

install -d -m 755 "$BACKUP_DIR"
cd "$SRC"

# اجمع كل ملفات .sh دون استثناءات
find . -type f -name '*.sh' -printf '%P\0' > "$TMP"
if [[ ! -s "$TMP" ]]; then
  log "لا توجد ملفات .sh في $SRC"
  rm -f "$TMP"
  exit 2
fi

# أنشئ الأرشيف + قائمة الملفات
tar -czf "$OUT" -C "$SRC" --null -T "$TMP"
tr '\0' '\n' < "$TMP" > "$LIST"
rm -f "$TMP"

sha256sum "$OUT" | tee "$SHA" >/dev/null
chmod 600 "$OUT" "$SHA" "$LIST" || true

log "archive: $OUT"
log "sha256: $(cut -d' ' -f1 "$SHA")"
log "list: $LIST"
