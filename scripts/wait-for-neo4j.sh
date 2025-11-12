#!/bin/bash
set -e
echo "⏳ انتظار Neo4j..."
until nc -z neo4j 7687; do
    sleep 5
done
echo "✅ Neo4j جاهز!"
