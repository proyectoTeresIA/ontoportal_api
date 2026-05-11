require 'redis'

module AnnotatorCacheRecovery
  AUTO_REPAIR_LOCK_KEY = 'annotator:auto_repair:lock'.freeze
  AUTO_REPAIR_LAST_RUN_KEY = 'annotator:auto_repair:last_run'.freeze

  def maybe_repair_annotator_cache!(context: 'annotator')
    redis = annotator_redis_client
    return false if redis.nil?

    min_entries = ENV.fetch('ANNOTATOR_CACHE_MIN_ENTRIES', '1000').to_i
    cooldown_seconds = ENV.fetch('ANNOTATOR_AUTO_REPAIR_COOLDOWN_SECONDS', '900').to_i
    lock_seconds = ENV.fetch('ANNOTATOR_AUTO_REPAIR_LOCK_SECONDS', '300').to_i

    current_size = annotator_dictionary_size(redis)
    return false if current_size >= min_entries

    now = Time.now.to_i
    last_repair = redis.get(AUTO_REPAIR_LAST_RUN_KEY).to_i
    if last_repair.positive? && (now - last_repair) < cooldown_seconds
      Log.add :warn, "Skipping annotator cache auto-repair in #{context}: cooldown active (#{now - last_repair}s elapsed)."
      return false
    end

    lock_token = "#{Process.pid}-#{Thread.current.object_id}-#{now}"
    lock_acquired = redis.set(AUTO_REPAIR_LOCK_KEY, lock_token, nx: true, ex: lock_seconds)
    unless lock_acquired
      Log.add :warn, "Skipping annotator cache auto-repair in #{context}: lock already held."
      return false
    end

    begin
      Log.add :warn, "Annotator cache appears degraded in #{context} (size=#{current_size}, min=#{min_entries}). Attempting auto-repair."
      annotator = Annotator::Models::NcboAnnotator.new
      annotator.create_term_cache(nil, false)
      annotator.generate_dictionary_file
      redis.set(AUTO_REPAIR_LAST_RUN_KEY, now)

      repaired_size = annotator_dictionary_size(redis)
      Log.add :info, "Annotator cache auto-repair completed in #{context} (size=#{repaired_size})."
      repaired_size.positive?
    rescue StandardError => e
      Log.add :error, "Annotator cache auto-repair failed in #{context}: #{e.class} #{e.message}"
      false
    ensure
      begin
        redis.del(AUTO_REPAIR_LOCK_KEY) if redis.get(AUTO_REPAIR_LOCK_KEY) == lock_token
      rescue StandardError => e
        Log.add :warn, "Failed to release annotator cache auto-repair lock: #{e.class} #{e.message}"
      end
    end
  end

  private

  def annotator_redis_client
    Redis.new(
      host: Annotator.settings.annotator_redis_host,
      port: Annotator.settings.annotator_redis_port,
      timeout: 5
    )
  rescue StandardError => e
    Log.add :error, "Cannot connect to annotator Redis: #{e.class} #{e.message}"
    nil
  end

  def annotator_dictionary_size(redis)
    annotator = Annotator::Models::NcboAnnotator.new
    dict_key = "#{annotator.redis_current_instance}dict"
    redis.hlen(dict_key).to_i
  rescue StandardError => e
    Log.add :warn, "Cannot read annotator dictionary size: #{e.class} #{e.message}"
    0
  end
end