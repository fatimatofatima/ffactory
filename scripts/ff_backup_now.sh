#!/usr/bin/env bash
set -Eeuo pipefail
FF="/opt/ffactory"
BK="$FF/backups"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$BK/$TS"
mkdir -p "$OUT"

echo "[*] Backup to: $OUT"

# 0) ملفات التكوين
cp -a "$FF/stack/.env" "$OUT/.env" 2>/dev/null || true
tar -C "$FF" -czf "$OUT/ffactory_configs_${TS}.tgz" stack apps scripts || true

# 1) Postgres (منطقي وآمن أثناء التشغيل)
PGU="$(docker exec ffactory_db printenv POSTGRES_USER 2>/dev/null || echo forensic)"
PGDB="$(docker exec ffactory_db printenv POSTGRES_DB 2>/dev/null || echo ffactory)"
echo "[*] Dump Postgres: db=$PGDB user=$PGU"
docker exec -i ffactory_db pg_dump -U "$PGU" "$PGDB" \
  | gzip > "$OUT/postgres_${PGDB}_${TS}.sql.gz"

# 2) Redis (RDB)
echo "[*] Save Redis RDB"
docker exec ffactory_redis redis-cli --rdb /data/dump.rdb >/dev/null
docker cp ffactory_redis:/data/dump.rdb "$OUT/redis_${TS}.rdb"

# 3) Neo4j (لقطة للـ volume - سريعة لكنها "warm")
# لو عايز باك أب متّسق تمامًا لـ Neo4j اعمل إيقاف مؤقت للحاوية قبل السطر ده ثم شغّلها تاني.
echo "[*] Snapshot neo4j_data volume"
docker run --rm -v neo4j_data:/data alpine tar -C / -czf - data > "$OUT/neo4j_volume_${TS}.tar.gz"

# 4) Volumes مهمة إضافية (اختياري)
for v in postgres_data redis_data neo4j_data ollama_data case_data; do
  docker volume inspect "$v" >/dev/null 2>&1 || continue
  echo "[*] Snapshot volume: $v"
  docker run --rm -v "$v":/vol alpine tar -C / -czf - vol > "$OUT/vol_${v}_${TS}.tar.gz"
done
# ملاحظة: MinIO ممكن يكون حجمه كبير؛ فعّله يدويًا لو تحتاج:
# docker run --rm -v minio_data:/data alpine tar -C / -czf - data > "$OUT/minio_volume_${TS}.tar.gz"

# 5) مانيفست
{
  echo "FFactory backup $TS"
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep ffactory || true
} > "$OUT/MANIFEST.txt"

echo "[✓] Done. Folder: $OUT"
