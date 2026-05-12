#!/usr/bin/env ruby

require 'bundler/setup'
require 'ontologies_linked_data'
require 'ncbo_annotator'
require 'ncbo_ontology_recommender'
require 'ncbo_cron'
require_relative '../config/config'
require_relative '../config/environments/development'

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

ont = LinkedData::Models::Ontology.find('APSAN').first
abort('APSAN not found') unless ont

sub = ont.latest_submission(status: :any)
abort('APSAN latest submission not found') unless sub

sub.bring(:submissionId, :submissionStatus, :hasOntologyLanguage)
puts "submission=#{sub.submissionId}"
puts "status_before=#{sub.submissionStatus.map { |s| s.id.to_s.split('/').last }.join(',')}"
puts "lang=#{sub.hasOntologyLanguage&.id}"

begin
  puts 'index_start'
  sub.index(logger, commit: true, optimize: false)
  puts 'index_done'
rescue StandardError => e
  puts "index_error=#{e.class}: #{e.message}"
  puts e.backtrace.first(10)
end

begin
  puts 'metrics_start'
  LinkedData::Services::SubmissionMetricsCalculator.new(sub).process(logger)
  puts 'metrics_done'
rescue StandardError => e
  puts "metrics_error=#{e.class}: #{e.message}"
  puts e.backtrace.first(10)
end

begin
  conn = RSolr.connect(url: LinkedData.settings.lexical_search_server_url)
  response = conn.get('select', params: { q: '*:*', fq: 'submissionAcronym:APSAN', rows: 0 })
  puts "solr_lexical_docs=#{response['response']['numFound']}"
rescue StandardError => e
  puts "solr_error=#{e.class}: #{e.message}"
end

sub = ont.latest_submission(status: :any)
sub.bring(:submissionStatus, :metrics)
puts "status_after=#{sub.submissionStatus.map { |s| s.id.to_s.split('/').last }.join(',')}"
puts "metrics_present=#{!sub.metrics.nil?}"