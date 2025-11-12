#!/bin/bash
BACKUP_DIR="$FF/backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "📦 إنشاء نسخة احتياطية في: $BACKUP_DIR"
docker compose -f "$COMPOSE_MAIN" exec -T db pg_dump -U forensic_user ffactory_core > "$BACKUP_DIR/db_backup.sql"
tar -czf "$BACKUP_DIR/volumes_backup.tar.gz" "$STACK/volumes" 2>/dev/null || true
echo "✅ النسخ الاحتياطي تم بنجاح"
