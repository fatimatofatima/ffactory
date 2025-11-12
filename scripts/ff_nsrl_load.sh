#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory
DST="$FF/data/hashsets/nsrl.sqlite"
SRC="${1:-}"; [ -n "$SRC" ] || { echo "usage: $0 /path/to/NSRLFile.txt[.gz|.bz2]"; exit 1; }
DIR="$(dirname "$SRC")"; BAS="$(basename "$SRC")"
install -d -m 755 "$(dirname "$DST")"
docker run --rm -v "$DIR":/in:ro -v "$FF/data/hashsets":/data alpine:3.20 sh -lc '
set -e
apk add --no-cache sqlite gzip bzip2
DB=/data/nsrl.sqlite
[ -f "$DB" ] || sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS nsrl(sha1 TEXT PRIMARY KEY); CREATE INDEX IF NOT EXISTS nsrl_sha1 ON nsrl(sha1);"
case "$BAS" in
  *.gz)  gzip -dc "/in/$BAS" ;;
  *.bz2) bzip2 -dc "/in/$BAS" ;;
  *)     cat "/in/$BAS" ;;
esac | awk -F, "NR>1{gsub(/\\\"/,\"\"); print toupper(\$2)}" | awk "length(\$1)==40" | \
sqlite3 "$DB" ".mode csv" ".import /dev/stdin nsrl"
echo "NSRL imported into $DB"
' BAS="$BAS"
