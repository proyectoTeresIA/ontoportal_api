# Extension to NcboAnnotator to support OntoLex entities
# This file adds indexing capabilities for OntoLex Forms and LexicalConcepts

puts "[OntoLex Extension] Loading ncbo_annotator_ontolex_extension.rb"

module Annotator
  module Models
    class NcboAnnotator
      
      # Override create_term_cache_for_submission to support OntoLex
      alias_method :original_create_term_cache_for_submission, :create_term_cache_for_submission
      
      def create_term_cache_for_submission(logger, sub, redis=nil, redis_prefix=nil)
        # Call original method for standard ontologies
        original_create_term_cache_for_submission(logger, sub, redis, redis_prefix)
        
        # Check if this is an OntoLex ontology
        sub.bring(:hasOntologyLanguage) if sub.bring?(:hasOntologyLanguage)
        ont_lang = sub.hasOntologyLanguage
        
        # hasOntologyLanguage is an OntologyFormat object with an ID (URI)
        # The ID will be something like http://api:9393/ontology_formats/ONTOLEX
        is_ontolex = ont_lang && ont_lang.id.to_s.include?('ONTOLEX')
        
        logger.info("Checking ontology language: #{ont_lang.inspect} (ID: #{ont_lang&.id})")
        
        if is_ontolex
          logger.info("✓ OntoLex ontology detected! Creating term cache for OntoLex entities...")
          create_ontolex_term_cache(logger, sub, redis, redis_prefix)
        else
          logger.info("✗ Not an OntoLex ontology (language: #{ont_lang&.id}), skipping OntoLex indexing")
        end
      end
      
      private
      
      # Create term cache specifically for OntoLex entities
      def create_ontolex_term_cache(logger, sub, redis=nil, redis_prefix=nil)
        if sub.nil?
          logger.error("Error from create_ontolex_term_cache: submission is nil")
          return
        end
        
        multi_logger = LinkedData::Utils::MultiLogger.new(loggers: logger)
        log_path = sub.parsing_log_path
        logger1 = Logger.new(log_path)
        multi_logger.add_logger(logger1)
        
        redis ||= redis()
        redis_prefix ||= redis_current_instance()
        
        page = 1
        size = 500  # Smaller page size for OntoLex due to more complex data
        count_entries = 0
        
        begin
          time = Benchmark.realtime do
            sub.ontology.bring(:acronym) if sub.ontology.bring?(:acronym)
            ontResourceId = sub.ontology.id.to_s
            multi_logger.info("Caching OntoLex LexicalEntries for #{sub.ontology.acronym}")
            
            # Page through all LexicalEntries in the submission
            # We index through entries because they link forms to concepts
            paging = LinkedData::Models::OntoLex::LexicalEntry.in(sub)
              .include(:evokes, :form, :canonicalForm, :sense).page(page, size)
            
            begin
              entry_page = nil
              t0 = Time.now
              entry_page = paging.all()
              count_entries += entry_page.length
              multi_logger.info("Page #{page} - #{entry_page.length} entries retrieved in #{Time.now - t0} sec.")
              
              t0 = Time.now
              
              entry_page.each do |entry|
                begin
                  # Get the concept this entry evokes
                  concept_id = nil
                  
                  # Try to get concept from evokes attribute
                  if entry.evokes
                    concept_id = entry.evokes.is_a?(Array) ? entry.evokes.first : entry.evokes
                  end
                  
                  # If no evokes, try through senses
                  if concept_id.nil? && entry.sense
                    senses = entry.sense.is_a?(Array) ? entry.sense : [entry.sense]
                    senses.each do |sense_id|
                      begin
                        sense = LinkedData::Models::OntoLex::LexicalSense.find(sense_id).in(sub).include(:isLexicalizedSenseOf).first
                        if sense && sense.isLexicalizedSenseOf
                          concept_id = sense.isLexicalizedSenseOf
                          break
                        end
                      rescue => e
                        # Skip if sense not found
                      end
                    end
                  end
                  
                  next unless concept_id  # Skip entries without concepts
                  
                  # Collect all forms for this entry
                  form_ids = []
                  form_ids << entry.canonicalForm if entry.canonicalForm
                  if entry.form
                    form_ids.concat(entry.form.is_a?(Array) ? entry.form : [entry.form])
                  end
                  
                  # Index each form
                  form_ids.compact.uniq.each do |form_id|
                    begin
                      form = LinkedData::Models::OntoLex::Form.find(form_id).in(sub).include(:writtenRep).first
                      next unless form && form.writtenRep
                      
                      # Create term entry for this form's writtenRep pointing to the concept
                      create_term_entry(
                        redis,
                        redis_prefix,
                        ontResourceId,
                        concept_id.to_s,  # Point to the LexicalConcept
                        Annotator::Annotation::MATCH_TYPES[:type_preferred_name],
                        form.writtenRep.to_s,
                        []  # OntoLex doesn't have semantic types
                      )
                    rescue Exception => e
                      multi_logger.error("Error loading form #{form_id}: #{e.message}")
                    end
                  end
                  
                rescue Exception => e
                  multi_logger.error("Error indexing OntoLex entry #{entry.id}: #{e.class}: #{e.message}")
                end
              end
              
              multi_logger.info("Page #{page} cached in Annotator in #{Time.now - t0} sec.")
              page = entry_page.next_page
              
              if page
                paging.page(page)
              end
            end while !page.nil?
          end
          
          multi_logger.info("Completed caching OntoLex entries for: #{sub.ontology.acronym} (#{sub.id.to_s}) in #{time} sec. #{count_entries} entries.")
        rescue Exception => e
          msg = "Failed caching OntoLex entries for #{sub.ontology.acronym} (#{sub.id.to_s})"
          multi_logger.error(msg)
          multi_logger.error(e.message + "\n" + e.backtrace.join("\n\t"))
        end
        multi_logger.flush()
      end
      
    end
  end
end
