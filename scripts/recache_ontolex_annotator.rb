#!/usr/bin/env ruby
# Recache OntoLex annotator entries for all OntoLex ontologies.
# This script directly calls create_term_cache_for_submission for each OntoLex
# submission so results are available immediately without waiting for the queue.

require 'bundler/setup'
require './app'

logger = Logger.new($stdout)
logger.level = Logger::INFO

annotator = Annotator::Models::NcboAnnotator.new

logger.info("=== OntoLex Annotator Recache ===")
logger.info("Fetching all ontology submissions...")

ontolex_subs = []

begin
  # Find the ONTOLEX format
  all_formats = LinkedData::Models::OntologyFormat.all
  ontolex_format = all_formats.find { |f| f.id.to_s.include?('ONTOLEX') }

  if ontolex_format.nil?
    logger.error("Could not find ONTOLEX format! Available: #{all_formats.map { |f| f.id }.join(', ')}")
    exit 1
  end

  logger.info("Found ONTOLEX format: #{ontolex_format.id}")

  # Get all submissions with ONTOLEX language
  subs = LinkedData::Models::OntologySubmission
    .where(hasOntologyLanguage: ontolex_format)
    .include(:submissionId, :hasOntologyLanguage, ontology: [:acronym])
    .all

  # Find the latest submission per ontology
  by_ont = {}
  subs.each do |sub|
    sub.ontology.bring(:acronym) if sub.ontology.bring?(:acronym)
    sub.bring(:submissionId) if sub.bring?(:submissionId)
    acronym = sub.ontology.acronym
    existing = by_ont[acronym]
    if existing.nil? || sub.submissionId > existing.submissionId
      by_ont[acronym] = sub
    end
  end

  ontolex_subs = by_ont.values
  logger.info("Found #{ontolex_subs.length} OntoLex ontologies: #{ontolex_subs.map { |s| s.ontology.acronym }.join(', ')}")
rescue StandardError => e
  logger.error("Error fetching ontologies: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  exit 1
end

if ontolex_subs.empty?
  logger.info("No OntoLex ontologies found. Nothing to do.")
  exit 0
end

# Check current Redis cache size
redis = Redis.new(
  host: Annotator.settings.annotator_redis_host,
  port: Annotator.settings.annotator_redis_port
)
dict_key = "#{annotator.redis_current_instance}dict"
before_size = redis.hlen(dict_key)
logger.info("Redis annotator cache BEFORE: #{before_size} entries")

# Process each OntoLex ontology
ontolex_subs.each do |sub|
  acronym = sub.ontology.acronym
  logger.info("\n--- Processing #{acronym} ---")

  begin
    # Bring all needed attributes
    sub.bring_remaining
    sub.ontology.bring_remaining

    annotator.create_term_cache_for_submission(logger, sub)
    logger.info("✓ Completed #{acronym}")
  rescue StandardError => e
    logger.error("✗ Failed #{acronym}: #{e.class}: #{e.message}")
    logger.error(e.backtrace.first(5).join("\n"))
  end
end

# Regenerate dictionary
logger.info("\n--- Regenerating mgrep dictionary ---")
begin
  annotator.generate_dictionary_file
  logger.info("Dictionary regenerated.")
rescue StandardError => e
  logger.error("Failed to regenerate dictionary: #{e.message}")
end

after_size = redis.hlen(dict_key)
logger.info("\n=== Done ===")
logger.info("Redis annotator cache AFTER: #{after_size} entries (added #{after_size - before_size})")
