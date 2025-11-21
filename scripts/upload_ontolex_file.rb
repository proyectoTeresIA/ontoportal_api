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
require 'cgi'
require_relative '../config/config'
# Load the full API app so the script shares the exact same LinkedData configuration
# (env, docker overrides, middlewares) as the running service
require_relative '../app'

# Allow environment override similar to api/app.rb so this script targets the same backend
if ENV['OVERRIDE_CONFIG'] == 'true'
  LinkedData.config do |config|
    config.goo_backend_name  = ENV['GOO_BACKEND_NAME'] if ENV['GOO_BACKEND_NAME']
    config.goo_host          = ENV['GOO_HOST']         if ENV['GOO_HOST']
    config.goo_port          = ENV['GOO_PORT'].to_i    if ENV['GOO_PORT']
    config.goo_path_query    = ENV['GOO_PATH_QUERY']   if ENV['GOO_PATH_QUERY']
    config.goo_path_data     = ENV['GOO_PATH_DATA']    if ENV['GOO_PATH_DATA']
    config.goo_path_update   = ENV['GOO_PATH_UPDATE']  if ENV['GOO_PATH_UPDATE']
    config.goo_redis_host    = ENV['REDIS_HOST']       if ENV['REDIS_HOST']
    config.goo_redis_port    = ENV['REDIS_PORT']       if ENV['REDIS_PORT']
    config.http_redis_host   = ENV['REDIS_HOST']       if ENV['REDIS_HOST']
    config.http_redis_port   = ENV['REDIS_PORT']       if ENV['REDIS_PORT']
    # URL prefixes
    config.rest_url_prefix   = ENV['REST_URL_PREFIX']  if ENV['REST_URL_PREFIX']
    config.id_url_prefix     = ENV['REST_URL_PREFIX']  if ENV['REST_URL_PREFIX']
  end
end

REST = ENV['REST_URL_PREFIX'] || LinkedData.settings.rest_url_prefix || 'http://localhost:9393/'

def ensure_contact
  c = LinkedData::Models::Contact.new
  c.name = 'Admin'
  c.email = 'admin@example.org'
  c.save
  c
end

def ensure_admin_user
  # Find admin user by username; create a minimal admin if missing
  user = LinkedData::Models::User.find('admin').first
  unless user
    user = LinkedData::Models::User.new(username: 'admin', email: 'admin@example.org', password: 'changeme')
    unless user.save
      raise "Failed to create admin user: #{user.errors.inspect}"
    end
  end
  user
end

# Resolve file path relative to project root (Dir.pwd in container)
# When running from repo root (/srv/ontoportal/ontologies_api), ontologias is a sibling of api
# Resolve file path; by default, expect it under tmp at project root (api folder in container)
tmp_dir = File.join(Dir.pwd, 'tmp')
FileUtils.mkdir_p(tmp_dir)
default_name = 'ejemplo_sintetico.ttl'
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
  ont.viewingRestriction = :public
  # Ensure we have a persisted admin user to satisfy ontology validations
  admin_user = ensure_admin_user
  ont.administeredBy = [admin_user]
  unless ont.save
    warn "Ontology invalid: #{ont.errors.inspect}"
    exit 1
  end
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

# Use the OntoLex parser which properly saves entities via Goo's .save() method
# This ensures that Goo's .in().ids().include().all patterns work correctly
puts "[OntoLex] Parsing and saving entities via Goo (this may take a while)..."
begin
  result = LinkedData::Parser::OntoLex.parse(file.to_s, sub)
  if result
    puts "[OntoLex] Successfully parsed and saved:"
    puts "  - Entries: #{result[:entries]&.length || 0}"
    puts "  - Senses: #{result[:senses]&.length || 0}"
    puts "  - Concepts: #{result[:concepts]&.length || 0}"
    puts "  - Forms: #{result[:forms]&.length || 0}"
  else
    puts "[OntoLex] Parser completed (no return value)"
  end
rescue StandardError => e
  warn "[ERROR] OntoLex parser failed: #{e.class}: #{e.message}"
  e.backtrace&.first(15)&.each { |ln| warn "  #{ln}" }
  exit 1
end

base_url = REST.chomp('/')
puts "Created #{acronym} submission ##{sub.submissionId} from: #{file}"
begin
  g = sub.id.to_s
  epr = Goo.sparql_query_client(:main)
  ontolex = 'http://www.w3.org/ns/lemon/ontolex#'
  lemon   = 'http://lemon-model.net/lemon#'

  q = lambda do |sparql|
    begin
      epr.query(sparql, graphs: [g])
    rescue StandardError => e
      warn "[OntoLex][verify] SPARQL error: #{e.class}: #{e.message}"
      []
    end
  end

  # Counts by type
  entry_row = q.call("SELECT (COUNT(DISTINCT ?s) AS ?c) WHERE { GRAPH <#{g}> { ?s a <#{ontolex}LexicalEntry> } }").first
  form_row  = q.call("SELECT (COUNT(DISTINCT ?f) AS ?c) WHERE { GRAPH <#{g}> { { ?f a <#{ontolex}Form> } UNION { ?f a <#{lemon}Form> } } }").first
  sense_row = q.call("SELECT (COUNT(DISTINCT ?se) AS ?c) WHERE { GRAPH <#{g}> { ?se a <#{ontolex}LexicalSense> } }").first
  concept_row = q.call("SELECT (COUNT(DISTINCT ?cpt) AS ?c) WHERE { GRAPH <#{g}> { ?cpt a <#{ontolex}LexicalConcept> } }").first
  entry_count = entry_row && entry_row[:c] ? entry_row[:c].to_i : nil
  form_count  = form_row  && form_row[:c]  ? form_row[:c].to_i  : nil
  sense_count = sense_row && sense_row[:c] ? sense_row[:c].to_i : nil
  concept_count = concept_row && concept_row[:c] ? concept_row[:c].to_i : nil

  puts "[OntoLex][verify] Counts in submission graph:"
  puts "  LexicalEntry:     #{entry_count || 'N/A'}"
  puts "  Form (ontolex/lemon): #{form_count || 'N/A'}"
  puts "  LexicalSense:     #{sense_count || 'N/A'}"
  puts "  LexicalConcept:   #{concept_count || 'N/A'}"

  # Relationship counts (entry→form, entry→sense, entry→evokes concept)
  rel_form_row = q.call([
    'SELECT (COUNT(?f) AS ?c) WHERE {',
    "  GRAPH <#{g}> {",
    "    ?s a <#{ontolex}LexicalEntry> .",
    "    ?s (<#{ontolex}form>|<#{ontolex}lexicalForm>|<#{ontolex}canonicalForm>|<#{ontolex}otherForm>|<#{lemon}form>|<#{lemon}canonicalForm>|<#{lemon}otherForm>) ?f .",
    '    FILTER(isIRI(?f))',
    '  }',
    '}'
  ].join("\n")).first
  rel_form_count = rel_form_row && rel_form_row[:c] ? rel_form_row[:c].to_i : nil

  rel_sense_row = q.call([
    'SELECT (COUNT(?se) AS ?c) WHERE {',
    "  GRAPH <#{g}> {",
    "    ?s a <#{ontolex}LexicalEntry> .",
    "    { ?s <#{ontolex}sense> ?se } UNION { ?se <#{ontolex}isSenseOf> ?s } UNION { ?s <#{ontolex}evokes> ?c . ?c <#{ontolex}lexicalizedSense> ?se } .",
    '    FILTER(isIRI(?se))',
    '  }',
    '}'
  ].join("\n")).first
  rel_sense_count = rel_sense_row && rel_sense_row[:c] ? rel_sense_row[:c].to_i : nil

  evokes_row = q.call([
    'SELECT (COUNT(?cpt) AS ?c) WHERE {',
    "  GRAPH <#{g}> {",
    "    ?s a <#{ontolex}LexicalEntry> .",
    "    ?s <#{ontolex}evokes> ?cpt .",
    '  }',
    '}'
  ].join("\n")).first
  evokes_count = evokes_row && evokes_row[:c] ? evokes_row[:c].to_i : nil

  puts "[OntoLex][verify] Entry relations present:"
  puts "  entry → form edges:  #{rel_form_count || 'N/A'}"
  puts "  entry ↔ sense edges: #{rel_sense_count || 'N/A'}"
  puts "  entry → concept (evokes): #{evokes_count || 'N/A'}"

  # Sample one entry and show its forms/senses and a form's writtenRep
  sample_row = q.call("SELECT ?s WHERE { GRAPH <#{g}> { ?s a <#{ontolex}LexicalEntry> } } ORDER BY ?s LIMIT 1").first
  sample = sample_row && sample_row[:s] ? sample_row[:s].to_s : nil
  if sample && !sample.empty?
    puts "[OntoLex][verify] Sample entry: #{sample}"
    forms = q.call([
      'SELECT ?f WHERE {',
      "  GRAPH <#{g}> {",
      "    VALUES ?s { <#{sample}> }",
      "    ?s (<#{ontolex}form>|<#{ontolex}lexicalForm>|<#{ontolex}canonicalForm>|<#{ontolex}otherForm>|<#{lemon}form>|<#{lemon}canonicalForm>|<#{lemon}otherForm>) ?f .",
      '    FILTER(isIRI(?f))',
      '  }',
      '}'
    ].join("\n")).map { |r| r[:f].to_s }
    puts "  forms linked: #{forms.length}"

    if forms.any?
      f0 = forms.first
      wrs = q.call([
        'SELECT ?w WHERE {',
        "  GRAPH <#{g}> {",
        "    VALUES ?f { <#{f0}> }",
        "    { ?f <#{ontolex}writtenRep> ?w } UNION { ?f <#{lemon}writtenRep> ?w }",
        '  }',
        '}'
      ].join("\n")).map { |r| r[:w].to_s }
      puts "  first form writtenRep: #{wrs.uniq.join(' | ')}"
    end

    senses = q.call([
      'SELECT ?se WHERE {',
      "  GRAPH <#{g}> {",
      "    VALUES ?s { <#{sample}> }",
      "    { ?s <#{ontolex}sense> ?se } UNION { ?se <#{ontolex}isSenseOf> ?s } UNION { ?s <#{ontolex}evokes> ?c . ?c <#{ontolex}lexicalizedSense> ?se } .",
      '    FILTER(isIRI(?se))',
      '  }',
      '}'
    ].join("\n")).map { |r| r[:se].to_s }
    puts "  senses linked: #{senses.length}"
  else
    puts "[OntoLex][verify] No sample LexicalEntry found to inspect."
  end
rescue StandardError => e
  warn "[OntoLex][verify] Verification failed: #{e.class}: #{e.message}"
end

puts "Try endpoints:"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries'"
puts "  # Inspect ids from the list above, then:"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/<url-encoded-entry-id>'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/<url-encoded-entry-id>/forms'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/<url-encoded-entry-id>/senses'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/<url-encoded-entry-id>/concepts'"
