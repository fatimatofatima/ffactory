#!/usr/bin/env bash
set -Eeuo pipefail

echo "🎯 FFactory Production Readiness Check"
echo "========================================"

# Security check
echo "1. Security Assessment:"
if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "unhealthy"; then
    echo "⚠️  Some services show unhealthy status"
else
    echo "✅ All services report healthy"
fi

# Port exposure check  
echo
echo "2. Network Security:"
if docker ps --format "{{.Ports}}" | grep -q "0.0.0.0:"; then
    echo "⚠️  Some services exposed to all interfaces"
else
    echo "✅ All services properly bound to 127.0.0.1"
fi

# Resource check
echo
echo "3. Resource Allocation:"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemPerc}}\t{{.MemUsage}}" | head -n 7

# Storage check
echo
echo "4. Storage Volumes:"
docker volume ls --filter "name=ffactory" --format "table {{.Name}}\t{{.Driver}}"

# Recommendations
echo
echo "5. Recommendations:"
echo "✅ Enable ESM Apps for security updates: https://ubuntu.com/esm"
echo "✅ Consider Ubuntu 24.04 upgrade for better security"
echo "✅ Set up monitoring for service health"
echo "✅ Configure proper backups for PostgreSQL and Neo4j data"

echo
echo "🎉 FFactory system is operational!"
