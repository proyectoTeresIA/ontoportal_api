#!/usr/bin/env ruby
# Diagnostic script to inspect triples for a LexicalConcept in the current submission graph
# Usage:
#   ACRONYM=AS_LEX CONCEPT=http://example.org/Concept ruby scripts/check_ingest.rb

# Configure LinkedData directly from ENV (don’t load the API/Sinatra app)
require 'ontologies_linked_data'

include LinkedData

# Minimal configuration driven by environment variables. This avoids relying on
# app.rb and OVERRIDE_CONFIG and works for direct CLI execution.
LinkedData.config do |config|
  config.goo_backend_name = ENV.fetch('GOO_BACKEND_NAME', 'ag')
  config.goo_host         = ENV.fetch('GOO_HOST', 'localhost')
  config.goo_port         = Integer(ENV.fetch('GOO_PORT', '10035'))
  config.goo_path_query   = ENV.fetch('GOO_PATH_QUERY', '/repositories/ontoportal_test')
  config.goo_path_data    = ENV.fetch('GOO_PATH_DATA', '/repositories/ontoportal_test/statements')
  config.goo_path_update  = ENV.fetch('GOO_PATH_UPDATE', '/repositories/ontoportal_test/statements')

  # Caches/security off for a diagnostic script
  Goo.use_cache            = false
  config.enable_http_cache = false
  config.enable_security   = false

  # Optional but harmless in CLI context
  config.rest_url_prefix = ENV['REST_URL_PREFIX'] if ENV['REST_URL_PREFIX']
  config.id_url_prefix   = ENV['ID_URL_PREFIX']   if ENV['ID_URL_PREFIX']
end

acronym = ENV["ACRONYM"] || ARGV[0] || "AS_LEX"
concept_iri = ENV["CONCEPT"] || ARGV[1] || "http://myexample.com/terminologia-ld/terminologia_dels_aparells_sanitaris_C100"

client = Goo.sparql_query_client(:main)

# Try to resolve ontology/submission via metadata; if not available, fall back to graph discovery
graph_id = nil
begin
  ont = Models::Ontology.find(acronym).first || Models::Ontology.where(acronym: acronym).to_a.first
  if ont
    ont.bring(:submissions) if ont.bring?(:submissions)
    sub = ont.latest_submission
    if sub
      sub.bring(:submissionId) if sub.bring?(:submissionId)
      graph_id = sub.id.to_s
      puts "GRAPH(from metadata)=#{graph_id} SUBMISSION_ID=#{sub.submissionId}"
    else
      warn "NO_SUBMISSION for #{acronym} (metadata present but no submissions)"
    end
  else
    warn "NO_ONTOLOGY for #{acronym} (metadata not found)"
  end
rescue => e
  warn "Metadata lookup failed: #{e.class}: #{e.message}"
end

if graph_id.nil?
  # Discover graph containing the concept
  q_graph = "SELECT ?g (COUNT(?p) AS ?c) WHERE { GRAPH ?g { <#{concept_iri}> ?p ?o } } GROUP BY ?g ORDER BY DESC(?c)"
  graphs = client.query(q_graph)
  if graphs.any?
    # Prefer a graph matching the REST URL pattern for submissions if present
    candidate = graphs.find { |r| r[:g].to_s.include?("/ontologies/") && r[:g].to_s.include?("/submissions/") }
    graph_id = (candidate || graphs.first)[:g].to_s
    puts "GRAPH(from discovery)=#{graph_id} TRIPLE_COUNT=#{(candidate || graphs.first)[:c]}"
  else
    abort "NO_GRAPH_FOR_CONCEPT: #{concept_iri}"
  end
end

# Basic triple count for the concept in the submission graph
q_count = "SELECT (COUNT(?p) AS ?c) WHERE { GRAPH <#{graph_id}> { <#{concept_iri}> ?p ?o } }"
res1 = client.query(q_count, graphs: [graph_id]).first
puts "TRIPLES_ON_CONCEPT=#{res1 && res1[:c] ? res1[:c].to_s : "0"}"

# List a sample of triples for the concept
q_props = "SELECT ?p ?o WHERE { GRAPH <#{graph_id}> { <#{concept_iri}> ?p ?o } } ORDER BY ?p LIMIT 200"
client.query(q_props, graphs: [graph_id]).each { |row| puts "P=#{row[:p]}\tO=#{row[:o]}" }

# Resolve prefLabels and definitions using model-like patterns (including node-based definitions)
pref = "http://www.w3.org/2004/02/skos/core#prefLabel"
xl_pref = "http://www.w3.org/2008/05/skos-xl#prefLabel"
xl_lit  = "http://www.w3.org/2008/05/skos-xl#literalForm"
rdfs_label = "http://www.w3.org/2000/01/rdf-schema#label"
dct_title = "http://purl.org/dc/terms/title"
skos_def = "http://www.w3.org/2004/02/skos/core#definition"
dct_def  = "http://purl.org/dc/terms/definition"
desc     = "http://purl.org/dc/terms/description"
comment  = "http://www.w3.org/2000/01/rdf-schema#comment"
lang_p   = "http://purl.org/dc/terms/language"

qd = <<SPARQL
SELECT ?kind ?label ?lang WHERE {
  GRAPH <#{graph_id}> {
    VALUES ?s { <#{concept_iri}> }
    { ?s <#{pref}> ?label BIND("prefLabel" AS ?kind) }
    UNION { ?s <#{xl_pref}> ?pl . ?pl <#{xl_lit}> ?label BIND("prefLabel" AS ?kind) }
    UNION { ?s <#{rdfs_label}> ?label BIND("prefLabel" AS ?kind) }
    UNION { ?s <#{dct_title}> ?label BIND("prefLabel" AS ?kind) }
    UNION { ?s <#{skos_def}> ?o . FILTER(isLiteral(?o)) BIND(?o AS ?label) BIND("defLit" AS ?kind) }
    UNION { ?s <#{skos_def}> ?def . FILTER(!isLiteral(?def)) OPTIONAL { ?def <#{rdfs_label}> ?label } OPTIONAL { ?def <#{lang_p}> ?lang } BIND("defNode" AS ?kind) }
    UNION { ?s <#{dct_def}> ?o2 . FILTER(isLiteral(?o2)) BIND(?o2 AS ?label) BIND("defLit" AS ?kind) }
    UNION { ?s <#{desc}> ?o3 . FILTER(isLiteral(?o3)) BIND(?o3 AS ?label) BIND("defLit" AS ?kind) }
    UNION { ?s <#{comment}> ?o4 . FILTER(isLiteral(?o4)) BIND(?o4 AS ?label) BIND("defLit" AS ?kind) }
  }
}
SPARQL

puts "--- LABEL/DEF RESOLUTION ---"
client.query(qd, graphs: [graph_id]).each do |row|
  puts "K=#{row[:kind]}\tLABEL=#{row[:label]}\tLANG=#{row[:lang]}"
end

# Check evokes/lexicalizedSense for context
evokes = "http://www.w3.org/ns/lemon/ontolex#evokes"
is_evoked_by = "http://www.w3.org/ns/lemon/ontolex#isEvokedBy"
lex_sense = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
qe = <<SPARQL
SELECT ?p ?obj WHERE {
  GRAPH <#{graph_id}> {
    VALUES ?s { <#{concept_iri}> }
    { ?s <#{is_evoked_by}> ?obj BIND(<#{is_evoked_by}> AS ?p) }
    UNION { ?s <#{lex_sense}> ?obj BIND(<#{lex_sense}> AS ?p) }
    UNION { ?entry <#{evokes}> ?s BIND(<#{evokes}> AS ?p) BIND(?entry AS ?obj) }
  }
}
SPARQL

puts "--- EVOKES/LEXICALIZEDSENSE ---"
client.query(qe, graphs: [graph_id]).each do |row|
  puts "P=#{row[:p]}\tOBJ=#{row[:obj]}"
end

puts "Done."
