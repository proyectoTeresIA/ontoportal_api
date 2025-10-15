#!/usr/bin/env ruby

# Parse an OntoLex ontology file (TTL or NT) using the ontologies_linked_data gem
# parser and output the parser's result as JSON (entries, senses, concepts, forms).
#
# Usage examples:
#   ruby api/scripts/ontolex_to_json.rb \
#     --file tmp/aparells_sanitarios_rdf.ttl --limit 10 --out out.json
#   FILE=ontologias/dispositivos_moviles_rdf.ttl ruby api/scripts/ontolex_to_json.rb
#   ruby api/scripts/ontolex_to_json.rb --file ontologias/foo.ttl --acronym FOO
#
# Notes:
# - This script avoids writing to a triplestore; it monkey-patches model persistence
#   to no-op so you can run it offline. It requires the ontologies_linked_data gem
#   present in this repo and uses its OntoLex parser implementation.

require 'bundler/setup'
require 'optparse'
require 'json'

# Load only the needed parts of ontologies_linked_data without auto-connecting to Goo
require 'ontologies_linked_data'
require 'rdf'
require 'rdf/turtle'
require 'rdf/ntriples'
require 'tmpdir'
require 'open3'

OPTS = {
  file: ENV['FILE'],
  limit: (ENV['LIMIT'] || 20).to_i,
  out: ENV['OUT'],
  pretty: (ENV['PRETTY'] || 'true') =~ /^(true|1|yes)$/i,
  acronym: ENV['ACRONYM']
}

OptionParser.new do |opts|
  opts.banner = 'Usage: ontolex_to_json.rb [options]'
  opts.on('-f', '--file PATH', 'Path to TTL/NT file') { |v| OPTS[:file] = v }
  opts.on('-l', '--limit N', Integer, 'Max number of entries in output (default 20)') { |v| OPTS[:limit] = v }
  opts.on('-o', '--out PATH', 'Write JSON to file (defaults to stdout)') { |v| OPTS[:out] = v }
  opts.on('--[no-]pretty', 'Pretty-print JSON (default: true)') { |v| OPTS[:pretty] = v }
  opts.on('-a', '--acronym ACR', 'Ontology acronym for dummy submission (default: derived from filename or TMP)') { |v| OPTS[:acronym] = v }
end.parse!

# Resolve default file if not provided
if OPTS[:file].nil? || OPTS[:file].strip.empty?
  candidates = [
    File.join(Dir.pwd, 'tmp', 'aparells_sanitarios_rdf.ttl'),
    File.join(Dir.pwd, 'api', 'tmp', 'aparells_sanitarios_rdf.ttl'),
    File.expand_path(File.join(Dir.pwd, '..', 'ontologias', 'aparells_sanitarios_rdf.ttl'))
  ]
  OPTS[:file] = candidates.find { |p| File.exist?(p) }
end

abort 'File not found. Provide --file PATH or set FILE=...' unless OPTS[:file] && File.exist?(OPTS[:file])

FILE_PATH = OPTS[:file]

# Configure ontologies_linked_data without connecting to Goo (no-op backend)
LinkedData.config do |config, overide_connect_goo|
  overide_connect_goo = true # prevent connect_goo
  # Minimal settings; adjust via env if needed
  config.goo_backend_name = ENV.fetch('GOO_BACKEND_NAME', '4store')
  config.goo_host         = ENV.fetch('GOO_HOST', 'localhost')
  config.goo_port         = ENV.fetch('GOO_PORT', '9000').to_i
  config.goo_path_query   = ENV.fetch('GOO_PATH_QUERY', '/sparql/')
  config.goo_path_data    = ENV.fetch('GOO_PATH_DATA', '/data/')
  config.goo_path_update  = ENV.fetch('GOO_PATH_UPDATE', '/update/')
  config.enable_http_cache = false
  config.enable_security    = false
end

# Disable persistence for this offline script
module LinkedData
  module Models
    class Base
      def in(_sub); self; end
      def save(*); self; end
    end
  end
end

# Build a minimal dummy Ontology and Submission required by the parser
acronym = OPTS[:acronym]
if acronym.nil? || acronym.strip.empty?
  base = File.basename(FILE_PATH, File.extname(FILE_PATH))
  acronym = base.gsub(/[^A-Za-z0-9]/, '').upcase
  acronym = 'TMP' if acronym.empty?
end

ontology = LinkedData::Models::Ontology.new(acronym: acronym, name: acronym)
submission = LinkedData::Models::OntologySubmission.new(ontology: ontology, submissionId: 1)

# Build RDF::Graph directly (avoids external 'rapper') and use gem's index_* methods
def build_graph(path)
  graph = RDF::Graph.new
  ext = File.extname(path).downcase
  reader_class = case ext
                 when '.nt', '.ntriples' then RDF::NTriples::Reader
                 when '.ttl', '.turtle' then RDF::Turtle::Reader
                 else RDF::Turtle::Reader
                 end
  File.open(path, 'rb') do |io|
    if reader_class == RDF::Turtle::Reader
      base = RDF::URI("file://#{File.expand_path(path)}")
      reader_class.new(io, base_uri: base) do |reader|
        reader.each_statement { |st| graph << st }
      end
    else
      reader_class.new(io) do |reader|
        reader.each_statement { |st| graph << st }
      end
    end
  end
  graph
end

parsed = nil
begin
  parsed = LinkedData::Parser::OntoLex.parse(FILE_PATH, submission)
rescue StandardError => e
  STDERR.puts("[OntoLex Script] Direct RDF parse failed: #{e.class}: #{e.message}.")
end

# Helpers to serialize Goo models and RDF values to plain JSON-compatible objects
def serialize_value(v)
  case v
  when Array
    v.map { |x| serialize_value(x) }
  else
    if v.respond_to?(:to_hash) && v.class.name.start_with?('LinkedData::Models')
      h = v.to_hash rescue {}
      # recursively serialize values
      h = h.each_with_object({}) { |(k, val), acc| acc[k.to_s] = serialize_value(val) }
      h['id'] ||= v.id.to_s if v.respond_to?(:id)
      h
    elsif v.respond_to?(:id) && v.class.name.start_with?('LinkedData::Models')
      { 'id' => v.id.to_s }
    else
      v.respond_to?(:to_s) ? v.to_s : v
    end
  end
end

def serialize_array(arr, limit=nil)
  list = Array(arr)
  list = list.first(limit) if limit && limit > 0
  list.map { |obj| serialize_value(obj) }
end

entries_serialized  = serialize_array(parsed[:entries], OPTS[:limit])
forms_serialized    = serialize_array(parsed[:forms])
senses_serialized   = serialize_array(parsed[:senses])
concepts_serialized = serialize_array(parsed[:concepts])

output = {
  'ontology' => {
    'source' => FILE_PATH,
    'acronym' => acronym,
    'submissionId' => 1,
    'counts' => {
      'entries' => Array(parsed[:entries]).length,
      'forms' => Array(parsed[:forms]).length,
      'senses' => Array(parsed[:senses]).length,
      'concepts' => Array(parsed[:concepts]).length
    },
    'returned' => {
      'entries' => entries_serialized.length
    }
  },
  'entries' => entries_serialized,
  'forms' => forms_serialized,
  'senses' => senses_serialized,
  'concepts' => concepts_serialized
}

json = OPTS[:pretty] ? JSON.pretty_generate(output) : JSON.generate(output)

if OPTS[:out]
  File.write(OPTS[:out], json)
  puts "Wrote #{OPTS[:out]} (#{File.size(OPTS[:out])} bytes)"
else
  puts json
end
