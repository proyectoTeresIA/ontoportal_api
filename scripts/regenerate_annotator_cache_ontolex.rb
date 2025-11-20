#!/usr/bin/env ruby

# Script to regenerate the annotator cache and dictionary file with OntoLex support
# Usage: ruby scripts/regenerate_annotator_cache_ontolex.rb [ontology_acronym]

# Load the complete application environment
require_relative '../app'
require 'logger'

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

# Get ontology acronym from command line or default to all OntoLex ontologies
target_acronym = ARGV[0]

logger.info("Starting annotator cache regeneration with OntoLex support...")

# Initialize annotator
annotator = Annotator::Models::NcboAnnotator.new(logger)

if target_acronym
  logger.info("Regenerating cache for ontology: #{target_acronym}")
  annotator.create_term_cache([target_acronym], true)
else
  # Find all OntoLex ontologies
  logger.info("Finding all OntoLex ontologies...")
  ontologies = LinkedData::Models::Ontology.where.include(:acronym, :submissions).all
  
  ontolex_acronyms = []
  ontologies.each do |ont|
    ont.bring(:submissions) if ont.bring?(:submissions)
    latest = ont.latest_submission(status: [:rdf])
    
    if latest
      latest.bring(:hasOntologyLanguage) if latest.bring?(:hasOntologyLanguage)
      # hasOntologyLanguage is an OntologyFormat object with an ID (URI)
      if latest.hasOntologyLanguage && latest.hasOntologyLanguage.id.to_s.include?('ONTOLEX')
        ontolex_acronyms << ont.acronym
        logger.info("Found OntoLex ontology: #{ont.acronym}")
      end
    end
  end
  
  if ontolex_acronyms.empty?
    logger.warn("No OntoLex ontologies found. Regenerating cache for all ontologies...")
    annotator.create_term_cache(nil, true)
  else
    logger.info("Regenerating cache for #{ontolex_acronyms.length} OntoLex ontologies...")
    annotator.create_term_cache(ontolex_acronyms, true)
  end
end

logger.info("Generating dictionary file...")
annotator.generate_dictionary_file()

logger.info("Switching to new cache instance...")
annotator.redis_switch_instance()

logger.info("Cache regeneration completed!")
logger.info("Dictionary file: #{Annotator.settings.mgrep_dictionary_file}")
