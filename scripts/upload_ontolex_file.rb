#!/usr/bin/env ruby

# Upload a TTL OntoLex ontology file (default: ontologias/aparells_sanitarios_rdf.ttl)
# - Creates an ontology with an acronym (default: AS_LEX)
# - Creates a submission, marks it RDF-ready, parses with OntoLex parser
# - Prints useful API endpoints

require 'bundler/setup'
require 'ontologies_linked_data'
require 'ncbo_annotator'
require 'ncbo_ontology_recommender'
require 'ncbo_cron'
require 'rdf'
require 'rdf/turtle'
require 'rdf/ntriples'
require 'open3'
require 'shellwords'
require 'fileutils'
require_relative '../config/config'
require_relative '../config/environments/development'

REST = LinkedData.settings.rest_url_prefix || 'http://localhost:9393/'

def ensure_contact
  c = LinkedData::Models::Contact.new
  c.name = 'Admin'
  c.email = 'admin@example.org'
  c.save
  c
end

# Resolve file path relative to project root (Dir.pwd in container)
# When running from repo root (/srv/ontoportal/ontologies_api), ontologias is a sibling of api
# Resolve file path; by default, expect it under tmp at project root (api folder in container)
tmp_dir = File.join(Dir.pwd, 'tmp')
FileUtils.mkdir_p(tmp_dir)
default_name = 'aparells_sanitarios_rdf.ttl'
default_path = File.join(tmp_dir, default_name)
file = ENV['FILE'] || default_path
unless File.exist?(file)
  # Try api/tmp when running from repo root
  alt1 = File.join(Dir.pwd, 'api', 'tmp', default_name)
  # Try ontologias folder
  alt2 = File.join(Dir.pwd, '..', 'ontologias', default_name)
  # Normalize relative traversal
  alt2 = File.expand_path(alt2)
  candidates = [file, alt1, alt2]
  found = candidates.find { |p| File.exist?(p) }
  if found
    file = found
  else
    warn "File not found. Tried:"
    candidates.each { |p| warn "  - #{p}" }
    warn "Set FILE=/absolute/path/to.ttl or copy the file into tmp/."
    exit 1
  end
end

acronym = ENV['ACRONYM'] || 'AS_LEX'
name    = ENV['NAME']    || 'Aparells Sanitaris OntoLex'

ont = LinkedData::Models::Ontology.find(acronym).first
unless ont
  ont = LinkedData::Models::Ontology.new
  ont.acronym = acronym
  ont.name = name
  ont.administeredBy = [LinkedData::Models::User.find('admin').first].compact
  ont.viewingRestriction = :public
  ont.save if ont.valid?
end

sub = LinkedData::Models::OntologySubmission.new
sub.ontology = ont
begin
  existing = LinkedData::Models::OntologySubmission.where(ontology: [acronym: acronym]).include(:submissionId).to_a
  max_id = existing.map { |s| s.submissionId.to_i }.max || 0
rescue StandardError
  max_id = 0
end
sub.submissionId = max_id + 1
sub.contact = [ensure_contact]
sub.released = DateTime.now
sub.uploadFilePath = file
if sub.respond_to?(:hasOntologyLanguage)
  fmt = LinkedData::Models::OntologyFormat.find('OWL').first
  sub.hasOntologyLanguage = fmt if fmt
end

status_uploaded = LinkedData::Models::SubmissionStatus.find('UPLOADED').first
status_rdf      = LinkedData::Models::SubmissionStatus.find('RDF').first
sub.add_submission_status(status_uploaded) if status_uploaded
sub.add_submission_status(status_rdf) if status_rdf

if sub.valid?
  sub.save
else
  puts "Submission invalid: #{sub.errors.inspect}"
  exit 1
end

# Parse OntoLex (ttl supported by rdf-turtle)
LinkedData::Parser::OntoLex.parse(file.to_s, sub)

# Explicitly load all triples from the TTL into the submission named graph in batches
begin
  g = sub.id.to_s
  puts "[OntoLex] Loading all triples into submission graph: #{g}"
  batch_size = Integer(ENV['BATCH'] || 1000)
  buffer = []
  count = 0
  flushed_batches = 0

  flush = lambda do
    return if buffer.empty?
    data = buffer.join("\n")
    sparql = "INSERT DATA { GRAPH <#{g}> {\n#{data}\n} }"
    Goo.sparql_update_client.update(sparql)
    count += buffer.length
    flushed_batches += 1
    puts "[OntoLex] Inserted batch ##{flushed_batches} (#{buffer.length} triples), total=#{count}"
    buffer.clear
  end

  # Prefer converting TTL->N-Triples with rapper and stream lines to avoid Ruby Turtle base URI quirks
  cmd = "rapper -i turtle -o ntriples #{Shellwords.escape(file)} 2>/dev/null"
  IO.popen(["bash", "-lc", cmd], "r") do |io|
    io.each_line do |line|
      line = line.strip
      next if line.empty?
      buffer << line
      flush.call if buffer.length >= batch_size
    end
  end
  flush.call
  puts "[OntoLex] Finished loading #{count} triples into submission graph"
rescue StandardError => e
  warn "[WARN] Failed to bulk load triples into submission graph: #{e.class}: #{e.message}"
  e.backtrace&.first(10)&.each { |ln| warn "  \e[90m#{ln}\e[0m" }
end

base_url = REST.chomp('/')
puts "Created #{acronym} submission ##{sub.submissionId} from: #{file}"
puts "Try endpoints:"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries'"
puts "  # Inspect ids from the list above, then:"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/<url-encoded-entry-id>'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/<url-encoded-entry-id>/forms'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/<url-encoded-entry-id>/senses'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/<url-encoded-entry-id>/concepts'"
