#!/bin/bash

# Production Deployment Script for OntoPortal API
# This script sets up and starts the production environment

set -e

echo "🚀 Starting OntoPortal API Production Environment..."

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running. Please start Docker first."
    exit 1
fi

# Create necessary directories for production data
echo "📁 Creating production data directories..."
mkdir -p ./production_data/{repository,mgrep/dictionary,logs}
mkdir -p ./production_redis
mkdir -p ./production_4store
mkdir -p ./production_logs
mkdir -p ./production_solr

# Check if production environment file exists
if [ ! -f .env.production ]; then
    echo "⚠️  Production environment file not found. Using defaults..."
    echo "💡 You can customize settings by editing .env.production"
else
    echo "✅ Using production environment file"
    export $(cat .env.production | grep -v '#' | xargs)
fi

# Build and start production services (independent)
echo "🔨 Building and starting production services..."
docker compose -f docker-compose.production.yml up --build -d

# Wait for services to be healthy
echo "⏳ Waiting for services to be healthy..."
docker compose -f docker-compose.production.yml ps

# Check if API is responding
echo "🔍 Checking API health..."
sleep 30

if curl -f http://localhost:9394/ > /dev/null 2>&1; then
    echo "✅ Production API is running at http://localhost:9394/"
    echo "📊 API Status:"
    curl -s http://localhost:9394/ | grep -o '"links":{"[^}]*}' | head -1
else
    echo "❌ API is not responding. Check logs:"
    docker compose -f docker-compose.production.yml logs api-production
    exit 1
fi

echo ""
echo "🎉 Production environment is ready!"
echo ""
echo "Production Services:"
echo "   • API: http://localhost:9394/"
echo "   • 4store Database: localhost:8082"
echo "   • Redis: localhost:6380"
echo "   • Solr Search: localhost:8984"

