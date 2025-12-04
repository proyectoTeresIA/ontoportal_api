#!/bin/bash
# Script to regenerate the annotator cache and dictionary
# Run this whenever the annotator returns empty results
# 
# Usage: ./scripts/regenerate_annotator_cache.sh [API_KEY]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTAL_DIR="$(dirname "$SCRIPT_DIR")/.."

# Get API key from argument or .env file
API_KEY="${1:-}"
if [ -z "$API_KEY" ]; then
    if [ -f "$PORTAL_DIR/.env" ]; then
        API_KEY=$(grep "^API_KEY=" "$PORTAL_DIR/.env" | cut -d'=' -f2)
    fi
fi

if [ -z "$API_KEY" ]; then
    echo "Error: API_KEY not provided and not found in .env"
    echo "Usage: $0 [API_KEY]"
    exit 1
fi

echo "=== Regenerating Annotator Cache ==="
echo "Portal directory: $PORTAL_DIR"
echo ""

cd "$PORTAL_DIR"

# Check current Redis cache status
echo "1. Checking current Redis cache status..."
REDIS_KEYS=$(docker compose -f docker-compose.production.yml --profile agraph exec -T redis-ut redis-cli DBSIZE | tr -d '[:space:]')
echo "   Current Redis keys: $REDIS_KEYS"

DICT_SIZE=$(docker compose -f docker-compose.production.yml --profile agraph exec -T redis-ut redis-cli HLEN "c1:dict" 2>/dev/null || echo "0")
echo "   Dictionary entries: $DICT_SIZE"

# Regenerate the cache
echo ""
echo "2. Regenerating annotator term cache..."
CACHE_RESPONSE=$(docker compose -f docker-compose.production.yml --profile agraph exec -T api-agraph \
    curl -s -X POST "http://localhost:9393/annotator/cache" \
    -H "Authorization: apikey token=$API_KEY" \
    -w "%{http_code}")

HTTP_CODE="${CACHE_RESPONSE: -3}"
if [ "$HTTP_CODE" != "200" ]; then
    echo "   ERROR: Cache regeneration failed with HTTP $HTTP_CODE"
    exit 1
fi
echo "   Cache regenerated successfully"

# Generate dictionary file
echo ""
echo "3. Generating dictionary file..."
DICT_RESPONSE=$(docker compose -f docker-compose.production.yml --profile agraph exec -T api-agraph \
    curl -s -X POST "http://localhost:9393/annotator/dictionary" \
    -H "Authorization: apikey token=$API_KEY" \
    -w "%{http_code}")

HTTP_CODE="${DICT_RESPONSE: -3}"
if [ "$HTTP_CODE" != "200" ]; then
    echo "   ERROR: Dictionary generation failed with HTTP $HTTP_CODE"
    exit 1
fi
echo "   Dictionary file generated"

# Restart mgrep to reload dictionary
echo ""
echo "4. Restarting mgrep to reload dictionary..."
docker compose -f docker-compose.production.yml --profile agraph restart mgrep-ut
echo "   mgrep restarted"

# Force Redis to save to disk
echo ""
echo "5. Forcing Redis to save data to disk..."
docker compose -f docker-compose.production.yml --profile agraph exec -T redis-ut redis-cli BGSAVE > /dev/null
sleep 2
echo "   Redis data saved"

# Verify results
echo ""
echo "6. Verifying results..."
NEW_DICT_SIZE=$(docker compose -f docker-compose.production.yml --profile agraph exec -T redis-ut redis-cli HLEN "c1:dict")
echo "   Dictionary entries: $NEW_DICT_SIZE"

DICT_FILE_LINES=$(docker compose -f docker-compose.production.yml --profile agraph exec -T api-agraph wc -l /srv/ontoportal/ontologies_api/test/data/dictionary.txt | awk '{print $1}')
echo "   Dictionary file lines: $DICT_FILE_LINES"

# Test annotator
echo ""
echo "7. Testing annotator..."
TEST_RESULT=$(curl -s -k "https://161.111.18.191/api/annotator?text=test&apikey=$API_KEY" | wc -c)
if [ "$TEST_RESULT" -gt 10 ]; then
    echo "   Annotator is responding with data"
else
    echo "   WARNING: Annotator returned minimal data - check your ontologies"
fi

echo ""
echo "=== Annotator Cache Regeneration Complete ==="
echo ""
