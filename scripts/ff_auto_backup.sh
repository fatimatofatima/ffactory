#!/bin/bash
echo "💾 بدء النسخ الاحتياطي التلقائي..."
docker exec ffactory_db pg_dump -U ffadmin ffactory_forensic > /opt/ffactory/backups/$(date +%Y%m%d_%H%M%S)_db_backup.sql
tar -czf /opt/ffactory/backups/$(date +%Y%m%d_%H%M%S)_neo4j_backup.tar.gz /opt/ffactory/data/neo4j_data/
echo "✅ تم النسخ الاحتياطي في: /opt/ffactory/backups/"
