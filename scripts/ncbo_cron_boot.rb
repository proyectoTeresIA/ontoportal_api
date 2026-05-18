require 'bundler/setup'
require './app'

LOG_FILE = File.open(
  File.join(ENV.fetch('LOG_PATH', '/srv/ontoportal/ontologies_api/log'), 'ncbo_cron_boot.log'),
  'a'
).tap { |f| f.sync = true }

def log(msg)
  line = "[ncbo_cron_boot] #{msg}"
  $stdout.puts line
  LOG_FILE.puts line
end

# ---------------------------------------------------------------------------
# 1. Annotator cache check (runs at startup and every ANNOTATOR_CACHE_CHECK_INTERVAL_HOURS)
# ---------------------------------------------------------------------------
ANNOTATOR_CACHE_CHECK_INTERVAL = Integer(ENV.fetch('ANNOTATOR_CACHE_CHECK_INTERVAL_HOURS', '8')) * 3600

def check_annotator_cache
  annotator = Annotator::Models::NcboAnnotator.new
  redis     = Redis.new(
    host: Annotator.settings.annotator_redis_host,
    port: Annotator.settings.annotator_redis_port
  )
  dict_key  = "#{annotator.redis_current_instance}dict"
  dict_size = redis.hlen(dict_key)
  log "Annotator cache size: #{dict_size} entries"

  if dict_size == 0
    log "Annotator cache empty - regenerating..."
    annotator.create_term_cache(nil, false)
    annotator.generate_dictionary_file
    log "Annotator cache regenerated: #{redis.hlen(dict_key)} entries"
  else
    log "Annotator cache OK"
  end
rescue StandardError => e
  log "Warning: annotator cache check failed (non-fatal): #{e.message}"
end

log "Checking annotator cache (startup)..."
check_annotator_cache

Thread.new do
  loop do
    sleep ANNOTATOR_CACHE_CHECK_INTERVAL
    log "Checking annotator cache (scheduled, every #{ANNOTATOR_CACHE_CHECK_INTERVAL / 3600}h)..."
    check_annotator_cache
  end
end

# ---------------------------------------------------------------------------
# 2. Uploaded submission watchdog (background Thread, shares loaded app)
# ---------------------------------------------------------------------------
REQUEUE_MIN_AGE_MINUTES            = Integer(ENV.fetch('REQUEUE_MIN_AGE_MINUTES',            '180'))
REQUEUE_NO_INDEXED_MIN_AGE_MINUTES = Integer(ENV.fetch('REQUEUE_NO_INDEXED_MIN_AGE_MINUTES', '300'))
REQUEUE_NO_RDF_MIN_AGE_MINUTES     = Integer(ENV.fetch('REQUEUE_NO_RDF_MIN_AGE_MINUTES',     '360'))
REQUEUE_INTERVAL_SECONDS    = Integer(ENV.fetch('REQUEUE_INTERVAL_SECONDS',    '300'))
ENABLE_WATCHDOG             = ENV.fetch('ENABLE_UPLOADED_REQUEUE_WATCHDOG', 'true') == 'true'

# Maps each required status to the action(s) that produce it.
# Processing order matters: process_rdf must come before downstream steps.
STATUS_ACTION_MAP = {
  'RDF'                => { process_rdf: true, generate_labels: true },
  'RDF_LABELS'         => { generate_labels: true },
  'INDEXED'            => { index_search: true },
  'INDEXED_PROPERTIES' => { index_properties: true },
  'METRICS'            => { run_metrics: true },
  'ANNOTATOR'          => { process_annotator: true },
}.freeze
REQUIRED_STATUSES = STATUS_ACTION_MAP.keys.freeze

# Returns the minimal set of actions needed to complete a submission.
# A step is included when its success status is absent OR when an ERROR_*
# for it is present (meaning it ran but failed and needs a retry).
def needed_actions(status_codes)
  actions = {}
  REQUIRED_STATUSES.each do |status|
    completed = status_codes.include?(status) && !status_codes.include?("ERROR_#{status}")
    next if completed
    STATUS_ACTION_MAP[status].each { |k, v| actions[k] = v }
  end
  actions
end

# Returns true if the submission is already sitting in the Redis parse queue.
def already_queued?(submission_id)
  queue_holder = NcboCron::Helpers::OntologyHelper::PROCESS_QUEUE_HOLDER
  prefix       = NcboCron::Helpers::OntologyHelper::REDIS_SUBMISSION_ID_PREFIX
  redis        = Redis.new(
    host: NcboCron.settings.redis_host,
    port: NcboCron.settings.redis_port
  )
  redis.hexists(queue_holder, "#{prefix}#{submission_id}")
rescue StandardError
  # If we can't check, err on the side of not requeuing to avoid duplicates
  true
end

def run_uploaded_requeue
  threshold_partial   = Time.now - (REQUEUE_MIN_AGE_MINUTES * 60)
  threshold_no_indexed = Time.now - (REQUEUE_NO_INDEXED_MIN_AGE_MINUTES * 60)
  threshold_no_rdf    = Time.now - (REQUEUE_NO_RDF_MIN_AGE_MINUTES * 60)
  parser    = NcboCron::Models::OntologySubmissionParser.new

  subs = begin
    uploaded = LinkedData::Models::SubmissionStatus.find('UPLOADED').first
    LinkedData::Models::OntologySubmission
      .where(submissionStatus: uploaded)
      .include(:submissionId, :creationDate, ontology: [:acronym])
      .all
  rescue StandardError
    LinkedData::Models::OntologySubmission
      .where
      .include(:submissionStatus, :submissionId, :creationDate, ontology: [:acronym])
      .all
  end

  requeued = 0
  checked  = 0
  skipped  = 0

  subs.each do |sub|
    checked += 1

    sub.bring(:submissionStatus) if sub.bring?(:submissionStatus)
    status_codes = Array(sub.submissionStatus).map do |st|
      st.bring(:code) if st.bring?(:code)
      st.code
    end.compact

    next unless status_codes.include?('UPLOADED')

    actions = needed_actions(status_codes)
    next if actions.empty?

    sub.bring(:creationDate) if sub.bring?(:creationDate)
    created_at = begin
      sub.creationDate ? Time.parse(sub.creationDate.to_s) : nil
    rescue StandardError
      nil
    end

    # Submissions whose RDF step has never succeeded could be actively parsing;
    # require a longer wait before declaring them stuck.
    # Submissions with RDF but no INDEXED could be actively indexing (the
    # slowest step); use an intermediate threshold.
    rdf_done     = status_codes.include?('RDF') || status_codes.include?('ERROR_RDF')
    indexed_done = status_codes.include?('INDEXED') || status_codes.include?('ERROR_INDEXED')
    threshold = if !rdf_done
                  threshold_no_rdf       # parsing may be in progress
                elsif !indexed_done
                  threshold_no_indexed   # indexing may be in progress
                else
                  threshold_partial      # only fast steps remain
                end
    next if created_at && created_at > threshold

    # Skip if this submission is already waiting in the parse queue
    if already_queued?(sub.id.to_s)
      skipped += 1
      next
    end

    parser.queue_submission(sub, actions)
    sub.bring(:submissionId) if sub.bring?(:submissionId)
    sub.bring(:ontology)     if sub.bring?(:ontology)
    sub.ontology.bring(:acronym) if sub.ontology&.bring?(:acronym)

    log "Requeued stale UPLOADED submission #{sub.id} (#{sub.ontology&.acronym}, submissionId=#{sub.submissionId}, actions=#{actions.keys.join(',')})"
    requeued += 1
  end

  log "Watchdog: checked #{checked} submissions, requeued #{requeued}, skipped #{skipped} (already queued)"
rescue StandardError => e
  log "Warning: watchdog pass failed (non-fatal): #{e.message}"
end

log "Running watchdog startup pass..."
run_uploaded_requeue

if ENABLE_WATCHDOG
  log "Starting watchdog thread (interval: #{REQUEUE_INTERVAL_SECONDS}s, min age: #{REQUEUE_MIN_AGE_MINUTES}m)"
  Thread.new do
    loop do
      sleep REQUEUE_INTERVAL_SECONDS
      run_uploaded_requeue
    end
  end
else
  log "Watchdog loop disabled"
end

# ---------------------------------------------------------------------------
# 3. ncbo_cron - main thread (foreground)
# ---------------------------------------------------------------------------
bin = ENV['NCBO_CRON_PATH']
abort("ERROR: ncbo_cron not found at: #{bin.inspect}") unless bin && File.file?(bin)

gem_root = File.expand_path('..', File.dirname(bin))
shim_cfg = File.join(gem_root, 'config', 'config.rb')
require 'fileutils'
FileUtils.mkdir_p(File.dirname(shim_cfg))
File.write(shim_cfg, "# shim: config loaded by ontologies_api\n") unless File.exist?(shim_cfg)

ARGV.concat(%w[--log-level info]) unless ARGV.include?('--log-level')
load bin