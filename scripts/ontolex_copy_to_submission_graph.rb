#!/usr/bin/env ruby

# Copy core OntoLex triples into the submission named graph for an existing ontology
# Usage: ACRONYM=AS_LEX ruby api/scripts/ontolex_copy_to_submission_graph.rb

require 'bundler/setup'
require 'ontologies_linked_data'
require 'ncbo_annotator'
require 'ncbo_ontology_recommender'
require 'ncbo_cron'
require_relative '../config/config'
require_relative '../config/environments/development'

acronym = ENV['ACRONYM']
abort 'Set ACRONYM=<ontology acronym>' if acronym.nil? || acronym.strip.empty?

ont = LinkedData::Models::Ontology.find(acronym).first
abort "Ontology not found: #{acronym}" unless ont
ont.bring(:latest_submission)
sub = ont.latest_submission
abort "No submission found for #{acronym}" unless sub

begin
  g = sub.id.to_s
  q = <<~SPARQL
  PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
  PREFIX rdfs: <https://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX ontolex: <http://www.w3.org/ns/lemon/ontolex#>
    PREFIX skos: <http://www.w3.org/2004/02/skos/core#>

    # Copy lexical entries and their relationships from any source graph
  INSERT { GRAPH <#{g}> { ?e ?type ontolex:LexicalEntry } }
  WHERE  { VALUES ?type { rdf:type rdfs:type }
       { GRAPH ?src { ?e ?type ontolex:LexicalEntry } FILTER (?src != <#{g}>) } UNION { ?e ?type ontolex:LexicalEntry } }
    ;
    INSERT { GRAPH <#{g}> { ?e ontolex:canonicalForm ?f } }
    WHERE  { GRAPH ?src { ?e ontolex:canonicalForm ?f } FILTER (?src != <#{g}>) }
    ;
    INSERT { GRAPH <#{g}> { ?e ontolex:otherForm ?f } }
    WHERE  { GRAPH ?src { ?e ontolex:otherForm ?f } FILTER (?src != <#{g}>) }
    ;
    # Copy forms and labels
  INSERT { GRAPH <#{g}> { ?f ?type ontolex:Form } }
  WHERE  { VALUES ?type { rdf:type rdfs:type }
       { GRAPH ?src { ?f ?type ontolex:Form } FILTER (?src != <#{g}>) } UNION { ?f ?type ontolex:Form } }
    ;
    INSERT { GRAPH <#{g}> { ?f ontolex:writtenRep ?wr } }
    WHERE  { GRAPH ?src { ?f ontolex:writtenRep ?wr } FILTER (?src != <#{g}>) }
    ;
    # Copy senses and concept links
    INSERT { GRAPH <#{g}> { ?e ontolex:sense ?s } }
    WHERE  { GRAPH ?src { ?e ontolex:sense ?s } FILTER (?src != <#{g}>) }
    ;
  INSERT { GRAPH <#{g}> { ?s ?type ontolex:LexicalSense } }
  WHERE  { VALUES ?type { rdf:type rdfs:type }
       { GRAPH ?src { ?s ?type ontolex:LexicalSense } FILTER (?src != <#{g}>) } UNION { ?s ?type ontolex:LexicalSense } }
    ;
    INSERT { GRAPH <#{g}> { ?s ontolex:isLexicalizedSenseOf ?c } }
    WHERE  { GRAPH ?src { ?s ontolex:isLexicalizedSenseOf ?c } FILTER (?src != <#{g}>) }
    ;
    # Copy concept basics
  INSERT { GRAPH <#{g}> { ?c ?type skos:Concept } }
  WHERE  { VALUES ?type { rdf:type rdfs:type }
       { GRAPH ?src { ?c ?type skos:Concept } FILTER (?src != <#{g}>) } UNION { ?c ?type skos:Concept } }
    ;
    INSERT { GRAPH <#{g}> { ?c skos:prefLabel ?pl } }
    WHERE  { GRAPH ?src { ?c skos:prefLabel ?pl } FILTER (?src != <#{g}>) }
  SPARQL
  Goo.sparql_update_client.update(q)
  puts "Copied OntoLex triples into submission graph for #{acronym} (submission ##{sub.submissionId})"
rescue StandardError => e
  warn "[WARN] Failed to copy OntoLex triples into submission graph: #{e.message}"
  exit 1
end
