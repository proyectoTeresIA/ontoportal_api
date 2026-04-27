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

# ============================================================================
# UPLOADED SUBMISSION WATCHDOG
# Re-queue stale UPLOADED submissions to prevent permanent stuck states
# when enqueueing is missed by transient failures.
# ============================================================================
REQUEUE_MIN_AGE_MINUTES="${REQUEUE_MIN_AGE_MINUTES:-60}"
REQUEUE_INTERVAL_SECONDS="${REQUEUE_INTERVAL_SECONDS:-300}"
ENABLE_UPLOADED_REQUEUE_WATCHDOG="${ENABLE_UPLOADED_REQUEUE_WATCHDOG:-true}"

REQUEUE_SCRIPT=$(cat <<'REQUEUERUBY'
require 'bundler/setup'
require './app'
require 'time'

min_age = Integer(ENV.fetch('REQUEUE_MIN_AGE_MINUTES', '60')) rescue 60
threshold = Time.now - (min_age * 60)
parser = NcboCron::Models::OntologySubmissionParser.new

subs = begin
  uploaded = LinkedData::Models::SubmissionStatus.find('UPLOADED').first
  LinkedData::Models::OntologySubmission.where(submissionStatus: uploaded)
    .include(:submissionId, :creationDate, ontology: [:acronym])
    .all
rescue StandardError
  LinkedData::Models::OntologySubmission.where
    .include(:submissionStatus, :submissionId, :creationDate, ontology: [:acronym])
    .all
end

requeued = 0
checked = 0

subs.each do |sub|
  checked += 1

  sub.bring(:submissionStatus) if sub.bring?(:submissionStatus)
  status_codes = (sub.submissionStatus || []).map do |st|
    st.bring(:code) if st.bring?(:code)
    st.code
  end.compact

  next unless status_codes.include?('UPLOADED')

  sub.bring(:creationDate) if sub.bring?(:creationDate)
  created_at = begin
    sub.creationDate ? Time.parse(sub.creationDate.to_s) : nil
  rescue StandardError
    nil
  end

  next if created_at && created_at > threshold

  parser.queue_submission(sub, { all: true })
  sub.bring(:submissionId) if sub.bring?(:submissionId)
  sub.bring(:ontology) if sub.bring?(:ontology)
  sub.ontology.bring(:acronym) if sub.ontology && sub.ontology.bring?(:acronym)

  puts "Requeued stale UPLOADED submission #{sub.id} (#{sub.ontology&.acronym}, submissionId=#{sub.submissionId})"
  requeued += 1
end

puts "Uploaded requeue watchdog checked #{checked} submissions; requeued #{requeued}."
REQUEUERUBY
)

run_uploaded_requeue_once() {
  echo "$REQUEUE_SCRIPT" | REQUEUE_MIN_AGE_MINUTES="$REQUEUE_MIN_AGE_MINUTES" bundle exec ruby || \
    echo "Warning: uploaded submission watchdog pass failed (non-fatal)"
}

echo "Running UPLOADED submission watchdog (startup pass)..."
run_uploaded_requeue_once

if [[ "$ENABLE_UPLOADED_REQUEUE_WATCHDOG" == "true" ]]; then
  echo "Starting UPLOADED submission watchdog loop every ${REQUEUE_INTERVAL_SECONDS}s (min age ${REQUEUE_MIN_AGE_MINUTES}m)."
  (
    while true; do
      sleep "$REQUEUE_INTERVAL_SECONDS"
      run_uploaded_requeue_once
    done
  ) &
else
  echo "UPLOADED submission watchdog loop disabled by ENABLE_UPLOADED_REQUEUE_WATCHDOG=${ENABLE_UPLOADED_REQUEUE_WATCHDOG}."
fi
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