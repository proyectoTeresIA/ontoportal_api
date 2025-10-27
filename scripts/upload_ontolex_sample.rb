#!/usr/bin/env ruby

# Upload a minimal OntoLex ontology (like the test fixture) and make it accessible via the API
# - Creates an ontology with an acronym (default: ONTOLEXAPI)
# - Creates a submission, marks it RDF-ready, and parses a tiny in-memory OntoLex N-Triples graph
# - Prints handy curl commands to explore endpoints

require 'bundler/setup'
require 'ontologies_linked_data'
require 'ncbo_annotator'
require 'ncbo_ontology_recommender'
require 'ncbo_cron'
require 'rdf'
require 'rdf/ntriples'
require 'fileutils'
require 'tmpdir'
require 'cgi'
require_relative '../config/config'
require_relative '../config/environments/development'

# Helpers
REST = LinkedData.settings.rest_url_prefix || 'http://localhost:9393/'

def ensure_contact
  c = LinkedData::Models::Contact.new
  c.name = 'Admin'
  c.email = 'admin@example.org'
  c.save
  c
end

acronym = ENV['ACRONYM'] || 'ONTOLEXAPI'
name    = ENV['NAME']    || 'OntoLex API Sample'

# Generate tiny OntoLex N-Triples like in tests
nt_data = <<~NT
  <http://example.org/lex/entry1> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/lemon/ontolex#LexicalEntry> .
  <http://example.org/lex/entry1> <http://www.w3.org/ns/lemon/ontolex#canonicalForm> <http://example.org/lex/form1> .
  <http://example.org/lex/form1>  <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/lemon/ontolex#Form> .
  <http://example.org/lex/form1>  <http://www.w3.org/ns/lemon/ontolex#writtenRep> "test"@en .
  <http://example.org/lex/entry1> <http://www.w3.org/ns/lemon/ontolex#sense> <http://example.org/lex/sense1> .
  <http://example.org/lex/sense1> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/lemon/ontolex#LexicalSense> .
  <http://example.org/lex/sense1> <http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf> <http://example.org/lex/concept1> .
  <http://example.org/lex/concept1> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/2004/02/skos/core#Concept> .
  <http://example.org/lex/concept1> <http://www.w3.org/2004/02/skos/core#prefLabel> "Test concept"@en .
NT

# Write to a writable system temp path to avoid project permissions issues
base = Dir.tmpdir
nt_path = File.join(base, 'ontolex_sample_upload.nt')
begin
  FileUtils.rm_f(nt_path)
rescue StandardError
end
File.write(nt_path, nt_data)

# Create ontology (or update)
ont = LinkedData::Models::Ontology.find(acronym).first
unless ont
  ont = LinkedData::Models::Ontology.new
  ont.acronym = acronym
  ont.name = name
  admin = LinkedData::Models::User.find('admin').first
  ont.administeredBy = [admin].compact
  ont.viewingRestriction = :public
  ont.save if ont.valid?
end

# Create submission
sub = LinkedData::Models::OntologySubmission.new
sub.ontology = ont
# Compute next submission id from existing submissions for this ontology
begin
  existing = LinkedData::Models::OntologySubmission.where(ontology: [acronym: acronym]).include(:submissionId).to_a
  max_id = existing.map { |s| s.submissionId.to_i }.max || 0
rescue StandardError
  max_id = 0
end
sub.submissionId = max_id + 1
sub.contact = [ensure_contact]
sub.released = DateTime.now
# Use local upload file path so processing can access it
sub.uploadFilePath = nt_path
# OntologyFormat: use OWL so validations pass; OntoLex parsing is done after
if sub.respond_to?(:hasOntologyLanguage)
  fmt = LinkedData::Models::OntologyFormat.find('OWL').first
  sub.hasOntologyLanguage = fmt if fmt
end

# Add statuses UPLOADED + RDF (we'll parse OntoLex below)
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

# Parse OntoLex into the submission graph
LinkedData::Parser::OntoLex.parse(nt_path.to_s, sub)

# Ensure triples are present in the submission named graph (some stores may load to default graph)
begin
  g = sub.id.to_s
  q = <<~SPARQL
  PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
  PREFIX rdfs: <https://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX ontolex: <http://www.w3.org/ns/lemon/ontolex#>
    PREFIX skos: <http://www.w3.org/2004/02/skos/core#>

  INSERT { GRAPH <#{g}> { ?e ?type ontolex:LexicalEntry } }
  WHERE  { VALUES ?type { rdf:type rdfs:type }
       { GRAPH ?src { ?e ?type ontolex:LexicalEntry } FILTER (?src != <#{g}>) } UNION { ?e ?type ontolex:LexicalEntry } }
    ;
    INSERT { GRAPH <#{g}> { ?e ontolex:canonicalForm ?f } }
    WHERE  { { GRAPH ?src { ?e ontolex:canonicalForm ?f } FILTER (?src != <#{g}>) } UNION { ?e ontolex:canonicalForm ?f } }
    ;
    INSERT { GRAPH <#{g}> { ?e ontolex:otherForm ?f } }
    WHERE  { { GRAPH ?src { ?e ontolex:otherForm ?f } FILTER (?src != <#{g}>) } UNION { ?e ontolex:otherForm ?f } }
    ;
  INSERT { GRAPH <#{g}> { ?f ?type ontolex:Form } }
  WHERE  { VALUES ?type { rdf:type rdfs:type }
       { GRAPH ?src { ?f ?type ontolex:Form } FILTER (?src != <#{g}>) } UNION { ?f ?type ontolex:Form } }
    ;
    INSERT { GRAPH <#{g}> { ?f ontolex:writtenRep ?wr } }
    WHERE  { { GRAPH ?src { ?f ontolex:writtenRep ?wr } FILTER (?src != <#{g}>) } UNION { ?f ontolex:writtenRep ?wr } }
    ;
    INSERT { GRAPH <#{g}> { ?e ontolex:sense ?s } }
    WHERE  { { GRAPH ?src { ?e ontolex:sense ?s } FILTER (?src != <#{g}>) } UNION { ?e ontolex:sense ?s } }
    ;
  INSERT { GRAPH <#{g}> { ?s ?type ontolex:LexicalSense } }
  WHERE  { VALUES ?type { rdf:type rdfs:type }
       { GRAPH ?src { ?s ?type ontolex:LexicalSense } FILTER (?src != <#{g}>) } UNION { ?s ?type ontolex:LexicalSense } }
    ;
    INSERT { GRAPH <#{g}> { ?s ontolex:isLexicalizedSenseOf ?c } }
    WHERE  { { GRAPH ?src { ?s ontolex:isLexicalizedSenseOf ?c } FILTER (?src != <#{g}>) } UNION { ?s ontolex:isLexicalizedSenseOf ?c } }
    ;
  INSERT { GRAPH <#{g}> { ?c ?type skos:Concept } }
  WHERE  { VALUES ?type { rdf:type rdfs:type }
       { GRAPH ?src { ?c ?type skos:Concept } FILTER (?src != <#{g}>) } UNION { ?c ?type skos:Concept } }
    ;
    INSERT { GRAPH <#{g}> { ?c skos:prefLabel ?pl } }
    WHERE  { { GRAPH ?src { ?c skos:prefLabel ?pl } FILTER (?src != <#{g}>) } UNION { ?c skos:prefLabel ?pl } }
  SPARQL
  Goo.sparql_update_client.update(q)
rescue StandardError => e
  warn "[WARN] Failed to copy OntoLex triples into submission graph: #{e.message}"
end
# Print endpoints
base_url = REST.chomp('/')
enc_id = CGI.escape('http://example.org/lex/entry1')
puts "Created #{acronym} submission ##{sub.submissionId} from: #{nt_path}"
puts "Try these endpoints:"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/#{enc_id}'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/#{enc_id}/forms'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/#{enc_id}/senses'"
puts "  curl '#{base_url}/ontologies/#{acronym}/lexical_entries/#{enc_id}/concepts'"
