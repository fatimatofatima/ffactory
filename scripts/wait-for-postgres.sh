#!/bin/bash
set -e
echo "⏳ انتظار PostgreSQL..."
until pg_isready -h db -p 5432 -U ${POSTGRES_USER:-ffadmin}; do
    sleep 5
done
echo "✅ PostgreSQL جاهز!"
