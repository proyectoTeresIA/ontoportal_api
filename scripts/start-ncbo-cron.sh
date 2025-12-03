#!/usr/bin/env bash
set -euo pipefail

# Run ncbo_cron from the API app directory so it can load config/config.rb
cd /srv/ontoportal/ontologies_api

# Configure bundler to use the shared path and install gems (no-op if already installed)
bundle config set --local path /srv/ontoportal/bundle
bundle install --quiet

# Default to production unless RACK_ENV is provided
export RACK_ENV="${RACK_ENV:-production}"
echo "Starting ncbo_cron in $RACK_ENV (cwd: $(pwd))"

# Minimal sanity check for config presence
[[ -f config/config.rb ]] || { echo "ERROR: missing config/config.rb"; exit 1; }

# Ensure the log directory and file exist before tailing
mkdir -p ./log
touch ./log/scheduler.log

# Capture app root and locate ncbo_cron script in the bundle
APP_ROOT="$(pwd)"
NCBO_CRON_PATH=$(find /srv/ontoportal/bundle -type f -name ncbo_cron | head -1 || true)
[[ -n "$NCBO_CRON_PATH" ]] || { echo "ERROR: ncbo_cron executable not found in bundle"; exit 1; }

# ============================================================================
# ANNOTATOR CACHE INITIALIZATION
# Ensure annotator cache is populated on startup
# ============================================================================
echo "Checking annotator cache status..."
INIT_SCRIPT=$(cat <<'INITRUBY'
require 'bundler/setup'
require './app'

annotator = Annotator::Models::NcboAnnotator.new
redis = Redis.new(host: Annotator.settings.annotator_redis_host, port: Annotator.settings.annotator_redis_port)
dict_key = "#{annotator.redis_current_instance}dict"
dict_size = redis.hlen(dict_key)

puts "Current annotator cache size: #{dict_size} entries"

if dict_size == 0
  puts "Annotator cache is empty - regenerating..."
  annotator.create_term_cache(nil, false)
  annotator.generate_dictionary_file()
  new_size = redis.hlen(dict_key)
  puts "Annotator cache regenerated: #{new_size} entries"
else
  puts "Annotator cache OK"
end
INITRUBY
)
echo "$INIT_SCRIPT" | bundle exec ruby || echo "Warning: Annotator cache initialization check failed (non-fatal)"
# ============================================================================

# Bootstrap Ruby: load bundler, then the app, then the ncbo_cron bin (with gem shim for config)
cat > /tmp/ncbo_cron_boot.rb <<'RUBY'
#!/usr/bin/env ruby
require 'bundler/setup'
require './app'

bin = ENV['NCBO_CRON_PATH']
abort("ncbo_cron script not found") unless bin && File.file?(bin)

app_root = ENV['APP_ROOT'] || Dir.pwd
Dir.chdir(app_root)

gem_root = File.expand_path('..', File.dirname(bin))
shim_cfg_dir = File.join(gem_root, 'config')
shim_cfg = File.join(shim_cfg_dir, 'config.rb')
require 'fileutils'
FileUtils.mkdir_p(shim_cfg_dir) unless File.directory?(shim_cfg_dir)
File.write(shim_cfg, "# shim: configuration loaded by ontologies_api app\n") unless File.exist?(shim_cfg)

ARGV.concat(%w[--log-level info]) unless ARGV.include?('--log-level')
load bin
RUBY

# Start ncbo_cron via the bootstrap and follow the scheduler log
APP_ROOT="$APP_ROOT" NCBO_CRON_PATH="$NCBO_CRON_PATH" bundle exec ruby /tmp/ncbo_cron_boot.rb &
tail -F ./log/scheduler.log