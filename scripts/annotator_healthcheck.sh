#!/bin/bash
# Healthcheck and auto-regeneration script for the annotator cache
# This script checks if the annotator cache is healthy and regenerates it if needed
#
# Usage: Run via cron or systemd timer
#   0 */4 * * * /path/to/scripts/annotator_healthcheck.sh >> /var/log/annotator_healthcheck.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTAL_DIR="$(dirname "$SCRIPT_DIR")"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Get API key from .env file
API_KEY=""
if [ -f "$PORTAL_DIR/.env" ]; then
    API_KEY=$(grep "^API_KEY=" "$PORTAL_DIR/.env" | cut -d'=' -f2)
fi

if [ -z "$API_KEY" ]; then
    echo "$LOG_PREFIX ERROR: API_KEY not found in .env"
    exit 1
fi

cd "$PORTAL_DIR"

# Check Redis dictionary entries
DICT_SIZE=$(docker compose -f docker-compose.production.yml --profile agraph exec -T redis-ut redis-cli HLEN "c1:dict" 2>/dev/null | tr -d '[:space:]' || echo "0")

# Check dictionary file lines
DICT_FILE_LINES=$(docker compose -f docker-compose.production.yml --profile agraph exec -T api-agraph wc -l /srv/ontoportal/ontologies_api/test/data/dictionary.txt 2>/dev/null | awk '{print $1}' || echo "0")

# Check mgrep dictionary
MGREP_DICT_LINES=$(docker compose -f docker-compose.production.yml --profile agraph exec -T mgrep-ut wc -l /srv/mgrep/dictionary/dictionary.txt 2>/dev/null | awk '{print $1}' || echo "0")

echo "$LOG_PREFIX Annotator Health Check"
echo "$LOG_PREFIX   Redis dict entries: $DICT_SIZE"
echo "$LOG_PREFIX   API dict file lines: $DICT_FILE_LINES"
echo "$LOG_PREFIX   mgrep dict lines: $MGREP_DICT_LINES"

# Check if cache is empty or files are mismatched
NEEDS_REGENERATION=false
NEEDS_DICTIONARY=false
NEEDS_MGREP_RESTART=false

if [ "$DICT_SIZE" = "0" ] || [ -z "$DICT_SIZE" ]; then
    echo "$LOG_PREFIX   WARNING: Redis cache is empty!"
    NEEDS_REGENERATION=true
fi

if [ "$DICT_FILE_LINES" != "$DICT_SIZE" ]; then
    echo "$LOG_PREFIX   WARNING: Dictionary file ($DICT_FILE_LINES) doesn't match Redis ($DICT_SIZE)"
    NEEDS_DICTIONARY=true
fi

if [ "$MGREP_DICT_LINES" != "$DICT_FILE_LINES" ]; then
    echo "$LOG_PREFIX   WARNING: mgrep dictionary ($MGREP_DICT_LINES) doesn't match API ($DICT_FILE_LINES)"
    NEEDS_MGREP_RESTART=true
fi

# Perform repairs if needed
if [ "$NEEDS_REGENERATION" = true ]; then
    echo "$LOG_PREFIX   Regenerating annotator cache..."
    RESPONSE=$(docker compose -f docker-compose.production.yml --profile agraph exec -T api-agraph \
        curl -s -X POST "http://localhost:9393/annotator/cache" \
        -H "Authorization: apikey token=$API_KEY" \
        -w "%{http_code}")
    HTTP_CODE="${RESPONSE: -3}"
    if [ "$HTTP_CODE" = "200" ]; then
        echo "$LOG_PREFIX   Cache regenerated successfully"
        NEEDS_DICTIONARY=true
    else
        echo "$LOG_PREFIX   ERROR: Cache regeneration failed with HTTP $HTTP_CODE"
        exit 1
    fi
fi

if [ "$NEEDS_DICTIONARY" = true ]; then
    echo "$LOG_PREFIX   Generating dictionary file..."
    RESPONSE=$(docker compose -f docker-compose.production.yml --profile agraph exec -T api-agraph \
        curl -s -X POST "http://localhost:9393/annotator/dictionary" \
        -H "Authorization: apikey token=$API_KEY" \
        -w "%{http_code}")
    HTTP_CODE="${RESPONSE: -3}"
    if [ "$HTTP_CODE" = "200" ]; then
        echo "$LOG_PREFIX   Dictionary file generated"
        NEEDS_MGREP_RESTART=true
    else
        echo "$LOG_PREFIX   ERROR: Dictionary generation failed with HTTP $HTTP_CODE"
        exit 1
    fi
fi

if [ "$NEEDS_MGREP_RESTART" = true ]; then
    echo "$LOG_PREFIX   Restarting mgrep..."
    docker compose -f docker-compose.production.yml --profile agraph restart mgrep-ut > /dev/null 2>&1
    echo "$LOG_PREFIX   mgrep restarted"
fi

# Force Redis save
if [ "$NEEDS_REGENERATION" = true ]; then
    echo "$LOG_PREFIX   Forcing Redis save..."
    docker compose -f docker-compose.production.yml --profile agraph exec -T redis-ut redis-cli BGSAVE > /dev/null 2>&1
    echo "$LOG_PREFIX   Redis save initiated"
fi

# Final verification
if [ "$NEEDS_REGENERATION" = true ] || [ "$NEEDS_DICTIONARY" = true ] || [ "$NEEDS_MGREP_RESTART" = true ]; then
    sleep 3
    NEW_DICT_SIZE=$(docker compose -f docker-compose.production.yml --profile agraph exec -T redis-ut redis-cli HLEN "c1:dict" 2>/dev/null | tr -d '[:space:]')
    echo "$LOG_PREFIX   Final Redis dict entries: $NEW_DICT_SIZE"
    echo "$LOG_PREFIX REPAIRS COMPLETED"
else
    echo "$LOG_PREFIX All checks passed - no action needed"
fi
