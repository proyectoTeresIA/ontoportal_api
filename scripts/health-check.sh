#!/bin/bash

# Production Health Check Script for OntoPortal API
# This script monitors the health of production services

echo "🔍 OntoPortal API Production Health Check"
echo "========================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check service health
check_service() {
    local service=$1
    local url=$2
    local name=$3
    
    if curl -f -s "$url" > /dev/null; then
        echo -e "✅ $name: ${GREEN}HEALTHY${NC}"
        return 0
    else
        echo -e "❌ $name: ${RED}UNHEALTHY${NC}"
        return 1
    fi
}

# Check Docker services status
echo "📊 Docker Services Status:"
docker compose -f docker-compose.yml -f docker-compose.production.yml ps --format "table {{.Name}}\t{{.State}}\t{{.Status}}"
echo ""

# Check individual service health
echo "🏥 Service Health Checks:"
check_service "api-production" "http://localhost:9394/" "OntoPortal API"
check_service "4store-production" "http://localhost:8082/sparql/" "4store Database"
check_service "redis-production" "http://localhost:6380/" "Redis Cache" || echo "  (Redis health check via HTTP not available)"

# Check Redis specifically
echo ""
echo "📊 Redis Status:"
if docker compose -f docker-compose.yml -f docker-compose.production.yml exec -T redis-production redis-cli ping > /dev/null 2>&1; then
    echo -e "✅ Redis: ${GREEN}RESPONDING${NC}"
    echo "   Memory usage: $(docker compose -f docker-compose.yml -f docker-compose.production.yml exec -T redis-production redis-cli info memory | grep used_memory_human | cut -d: -f2 | tr -d '\r')"
    echo "   Connected clients: $(docker compose -f docker-compose.yml -f docker-compose.production.yml exec -T redis-production redis-cli info clients | grep connected_clients | cut -d: -f2 | tr -d '\r')"
else
    echo -e "❌ Redis: ${RED}NOT RESPONDING${NC}"
fi

# Check disk usage
echo ""
echo "💾 Storage Usage:"
echo "Production data: $(docker run --rm -v production_data:/data alpine du -sh /data | cut -f1)"
echo "Production logs: $(docker run --rm -v production_logs:/logs alpine du -sh /logs | cut -f1)"
echo "4store data: $(docker run --rm -v production_4store:/4store alpine du -sh /4store | cut -f1)"
echo "Redis data: $(docker run --rm -v production_redis:/redis alpine du -sh /redis | cut -f1)"

# Check API endpoints
echo ""
echo "🔌 API Endpoints Check:"
if curl -f -s http://localhost:9394/ > /dev/null; then
    echo "✅ Root endpoint: ACCESSIBLE"
    
    # Test a few key endpoints
    endpoints=("ontologies" "categories" "users" "search")
    for endpoint in "${endpoints[@]}"; do
        if curl -f -s "http://localhost:9394/$endpoint" > /dev/null; then
            echo "✅ /$endpoint: ACCESSIBLE"
        else
            echo "⚠️  /$endpoint: NOT ACCESSIBLE (may require authentication)"
        fi
    done
else
    echo "❌ API not accessible"
fi

# Check logs for errors
echo ""
echo "📋 Recent Error Check:"
error_count=$(docker compose -f docker-compose.yml -f docker-compose.production.yml logs --tail=100 api-production 2>/dev/null | grep -i error | wc -l)
if [ "$error_count" -gt 0 ]; then
    echo -e "⚠️  Found ${YELLOW}$error_count${NC} error(s) in recent logs"
    echo "   Run: docker compose -f docker-compose.yml -f docker-compose.production.yml logs api-production | grep -i error"
else
    echo "✅ No recent errors found in logs"
fi

# Performance metrics
echo ""
echo "⚡ Performance Metrics:"
echo "API Response time: $(curl -w "@{time_total}" -o /dev/null -s http://localhost:9394/ 2>/dev/null)s"

# Summary
echo ""
echo "📈 Health Summary:"
all_healthy=true

services=("api-production" "redis-production" "4store-production")
for service in "${services[@]}"; do
    if docker compose -f docker-compose.yml -f docker-compose.production.yml ps --filter "name=$service" --format "{{.State}}" | grep -q "running"; then
        echo "✅ $service: Running"
    else
        echo "❌ $service: Not running"
        all_healthy=false
    fi
done

if $all_healthy; then
    echo -e "\n🎉 ${GREEN}All systems operational!${NC}"
else
    echo -e "\n⚠️  ${YELLOW}Some services need attention${NC}"
    exit 1
fi
