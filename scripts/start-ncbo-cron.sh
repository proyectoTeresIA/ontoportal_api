#!/usr/bin/env bash
set -euo pipefail

# Silence git ownership warnings for mounted volumes
git config --global --add safe.directory /srv/ontologies_linked_data 2>/dev/null || true
git config --global --add safe.directory /srv/ontoportal/ontologies_api 2>/dev/null || true

# Run from the API app directory so config/config.rb is on the load path
cd /srv/ontoportal/ontologies_api

bundle config set --local path /srv/ontoportal/bundle
bundle install --quiet

export RACK_ENV="${RACK_ENV:-production}"
echo "Starting ncbo_cron in $RACK_ENV (cwd: $(pwd))"

[[ -f config/config.rb ]] || { echo "ERROR: missing config/config.rb"; exit 1; }

mkdir -p ./log
touch ./log/scheduler.log

export APP_ROOT
APP_ROOT="$(pwd)"

export NCBO_CRON_PATH
NCBO_CRON_PATH=$(find /srv/ontoportal/bundle -type f -name ncbo_cron | head -1 || true)
[[ -n "$NCBO_CRON_PATH" ]] || { echo "ERROR: ncbo_cron executable not found in bundle"; exit 1; }

# Copy the boot script into /tmp so it's accessible at a known path
cp "$(dirname "$0")/ncbo_cron_boot.rb" /tmp/ncbo_cron_boot.rb

# exec replaces this shell with Ruby - Docker manages the process directly.
# All background work (watchdog thread) runs inside this single Ruby process.
exec bundle exec ruby /tmp/ncbo_cron_boot.rb