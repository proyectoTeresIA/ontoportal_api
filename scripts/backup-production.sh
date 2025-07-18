#!/bin/bash

# Production Backup Script for OntoPortal API
# This script backs up production data including database and Redis data

set -e

BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
echo "📦 Creating backup in: $BACKUP_DIR"

mkdir -p "$BACKUP_DIR"

# Stop the API temporarily to ensure consistent backup
echo "⏸️  Stopping API for backup..."
docker compose -f docker-compose.yml -f docker-compose.production.yml stop api-production

# Backup 4store database
echo "💾 Backing up 4store database..."
docker compose -f docker-compose.yml -f docker-compose.production.yml exec -T 4store-production 4s-dump-rdf ontoportal_production_kb > "$BACKUP_DIR/4store_backup.rdf"

# Backup Redis data
echo "💾 Backing up Redis data..."
docker compose -f docker-compose.yml -f docker-compose.production.yml exec -T redis-production redis-cli BGSAVE
sleep 5
docker cp $(docker compose -f docker-compose.yml -f docker-compose.production.yml ps -q redis-production):/data/dump.rdb "$BACKUP_DIR/redis_backup.rdb"

# Backup volumes
echo "💾 Backing up production data volumes..."
docker run --rm -v production_data:/data -v "$(pwd)/$BACKUP_DIR":/backup alpine tar czf /backup/production_data.tar.gz -C /data .
docker run --rm -v production_logs:/logs -v "$(pwd)/$BACKUP_DIR":/backup alpine tar czf /backup/production_logs.tar.gz -C /logs .

# Create backup metadata
echo "📝 Creating backup metadata..."
cat > "$BACKUP_DIR/backup_info.txt" << EOF
Backup created: $(date)
API Version: $(git rev-parse HEAD 2>/dev/null || echo "Unknown")
Docker Compose Version: $(docker compose version --short)
Services backed up:
- 4store database (ontoportal_production_kb)
- Redis data
- Production data volume
- Production logs volume
EOF

# Restart API
echo "▶️  Restarting API..."
docker compose -f docker-compose.yml -f docker-compose.production.yml start api-production

echo "✅ Backup completed successfully!"
echo "📂 Backup location: $BACKUP_DIR"
echo "📊 Backup size: $(du -sh $BACKUP_DIR | cut -f1)"

# Optional: Clean up old backups (keep last 7 days)
find ./backups -type d -mtime +7 -name "????????_??????" -exec rm -rf {} \; 2>/dev/null || true

echo "🧹 Old backups cleaned up (kept last 7 days)"
