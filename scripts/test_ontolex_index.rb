#!/usr/bin/env ruby

# Test script to manually trigger OntoLex indexing for ES ontology

# Navigate to API root
Dir.chdir File.expand_path('../..', __FILE__)

# Load the development environment
require_relative '../config/environments/development'

puts "Environment loaded successfully"
puts "Solr lexical search URL: #{LinkedData.settings.lexical_search_server_url}"

# Find the ES ontology
ont = LinkedData::Models::Ontology.find("ES").first
raise "Ontology ES not found!" unless ont

ont.bring(:acronym, :submissions)
latest = ont.latest_submission(status: :any)

raise "No submission found for ES!" unless latest

latest.bring(:submissionId, :submissionStatus)
puts "Latest submission: #{latest.submissionId} (status: #{latest.submissionStatus.map(&:id).join(', ')})"

# Force reindexing
puts "\nForcing reindexing of OntoLex entries..."
latest.index(Logger.new(STDOUT), commit: true, optimize: false)

puts "\nIndexing completed!"

# Verify in Solr
puts "\nVerifying Solr documents..."
conn = RSolr.connect(url: LinkedData.settings.lexical_search_server_url)
response = conn.get 'select', params: {q: '*:*', fq: 'submissionAcronym:ES', rows: 0}
puts "Documents in Solr for ES: #{response['response']['numFound']}"
