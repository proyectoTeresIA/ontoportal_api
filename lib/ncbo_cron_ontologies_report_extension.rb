puts "[OntoLex Extension] Loading ncbo_cron_ontologies_report_extension.rb"

module NcboCron
  module Models
    class OntologiesReport
      
      # Store reference to original method
      alias_method :original_good_classes, :good_classes
      
      # Override good_classes to get proper searchable terms for OntoLex
      def good_classes(submission, report)
        # Check if this is an OntoLex ontology
        begin
          # Ensure hasOntologyLanguage is loaded
          submission.bring(:hasOntologyLanguage) unless submission.loaded_attributes.include?(:hasOntologyLanguage)
          ont_lang = submission.hasOntologyLanguage
          is_ontolex = ont_lang && ont_lang.id.to_s.include?('ONTOLEX')
        rescue Exception => e
          @logger.error("[OntoLex Extension] Error checking ontology language: #{e.message}")
          is_ontolex = false
        end
        
        if is_ontolex
          acronym = submission.ontology.acronym rescue "UNKNOWN"
          @logger.info("[OntoLex Extension] Using OntoLex-specific term collection for #{acronym}")
          return get_good_lexical_forms(submission, report)
        else
          # Use original method for non-OntoLex ontologies
          return original_good_classes(submission, report)
        end
      end
      
      # New method: Get good searchable terms from OntoLex lexical forms
      def get_good_lexical_forms(submission, report)
        forms_size = 10
        good_forms = []
        page_num = 1
        page_size = 1000
        
        begin
          paging = LinkedData::Models::OntoLex::Form.in(submission)
                     .include(:writtenRep, :language)
                     .page(page_num, page_size)
          
          begin
            page_forms = paging.page(page_num, page_size).all
            
            page_forms.each do |form|
              written_rep = nil
              
              begin
                written_rep = form.writtenRep
              rescue Goo::Base::AttributeNotLoaded => e
                next
              end
              
              # Skip forms with no writtenRep, too short, or stop-words
              next if written_rep.nil? || written_rep.length < 3 || @stop_words.include?(written_rep.upcase)
              
              # Store good writtenRep
              good_forms << written_rep
              break if good_forms.length >= forms_size
            end
          rescue Exception => e
            @logger.error("[OntoLex Extension] Error during OntoLex form paging - #{e.class}: #{e.message}")
            add_error_code(report, :errRunningReport, ["get_good_lexical_forms_paging", e.class, e.message])
          end
          
        rescue Exception => e
          @logger.error("[OntoLex Extension] Error getting OntoLex forms - #{e.class}: #{e.message}")
          add_error_code(report, :errRunningReport, ["get_good_lexical_forms", e.class, e.message])
        end
        
        @logger.info("[OntoLex Extension] Collected #{good_forms.length} lexical forms for validation")
        return good_forms
      end
      
    end
  end
end

puts "[OntoLex Extension] Completed loading ncbo_cron_ontologies_report_extension.rb"
