# Extension to NcboCron::Models::OntologiesReport to support OntoLex validation
# This file adds proper search validation for OntoLex ontologies

puts "[OntoLex Extension] Loading ncbo_cron_ontologies_report_extension.rb"

module NcboCron
  module Models
    class OntologiesReport
      
      # Override generate_single_ontology_report to use OntoLex-aware validation
      alias_method :original_generate_single_ontology_report, :generate_single_ontology_report
      
      def generate_single_ontology_report(ont)
        report = {problem: false, format: '', date_created: '', administeredBy: [], logFilePath: '', report_date_updated: nil}
        ont.bring_remaining()
        ont.bring(:submissions)
        ont.bring(administeredBy: :username)
        report[:administeredBy] = []
        admin_by = nil

        begin
          admin_by = ont.administeredBy
        rescue
          sleep(3)
          ont.bring(administeredBy: :username)
          begin
            admin_by = ont.administeredBy
          rescue Exception => e
            admin_by = []
            add_error_code(report, :errRunningReport, ["ont.administeredBy", e.class, e.message])
          end
        end

        admin_by.each do |u|
          username = nil

          begin
            username = u.username
          rescue Exception => e
            add_error_code(report, :errRunningReport, ["u.username", e.class, e.message])
            username = u.id.split('/')[-1]
          end
          report[:administeredBy] << username
        end

        submissions = ont.submissions

        # first see if is summary only and if it has submissions
        if ont.summaryOnly
          if !submissions.nil? && submissions.length > 0
            add_error_code(report, :errSummaryOnlyWithSubmissions)
          else
            add_error_code(report, :summaryOnly)
          end
          ontology_report_date(report, "report_date_updated")
          return report
        end

        # check if latest submission is the one ready
        latest_any = ont.latest_submission(status: :any)

        if latest_any.nil?
          add_error_code(report, :errNoSubmissions)
          ontology_report_date(report, "report_date_updated")
          return report
        end

        latest_ready = ont.latest_submission(status: :ready)

        if latest_ready.nil?
          add_error_code(report, :errNoReadySubmission)
          ontology_report_date(report, "report_date_updated")
          return report
        end

        report[:format] = latest_ready.hasOntologyLanguage.to_s.split('/')[-1]
        report[:date_created] = ont.createdDate ? ont.createdDate.strftime("%m/%d/%Y, %I:%M %p") : ""
        report[:logFilePath] = log_file(ont.acronym, latest_ready.submissionId)

        # test if the latest ready is the latest
        if latest_any.submissionId > latest_ready.submissionId
          sub_count = 0
          latest_submission_id = latest_ready.submissionId.to_i
          ont.submissions.each { |sub| sub_count += 1 if sub.submissionId.to_i > latest_submission_id }
          add_error_code(report, :errNoLatestReadySubmission, sub_count)
        end

        # rest of the tests run for latest_ready
        sub = latest_ready
        sub.bring_remaining()
        sub.ontology.bring_remaining()
        sub.bring(:metrics)
        
        # Explicitly load hasOntologyLanguage for OntoLex detection
        sub.bring(:hasOntologyLanguage)

        # add error statuses
        sub.submissionStatus.each { |st| add_error_code(report, :errErrorStatus, st.get_code_from_id) if st.error? }

        # add missing statuses
        statuses = LinkedData::Models::SubmissionStatus.where.all
        statuses.select! { |st| !st.error? }
        statuses.select! { |st| st.id.to_s["DIFF"].nil? }
        statuses.select! { |st| st.id.to_s["ARCHIVED"].nil? }
        statuses.select! { |st| st.id.to_s["RDF_LABELS"].nil? }

        statuses.each do |ok|
          found = false

          sub.submissionStatus.each do |st|
            if st == ok
              found = true
              break
            end
          end
          add_error_code(report, :errMissingStatus, ok.get_code_from_id) unless found
        end

        # Check if this is an OntoLex ontology
        # Ensure hasOntologyLanguage is loaded
        begin
          sub.bring(:hasOntologyLanguage) unless sub.loaded_attributes.include?(:hasOntologyLanguage)
          ont_lang = sub.hasOntologyLanguage
          is_ontolex = ont_lang && ont_lang.id.to_s.include?('ONTOLEX')
        rescue Exception => e
          @logger.error("Error checking ontology language: #{e.class}: #{e.message}")
          add_error_code(report, :errRunningReport, ["check_ontolex", e.class, e.message])
          is_ontolex = false
        end

        # check whether ontology has been designated as "flat" or root classes exist
        if sub.ontology.flat
          add_error_code(report, :flat)
        else
          begin
            add_error_code(report, :errNoRootsLatestSubmission) unless sub.roots().length > 0
          rescue Exception => e
            add_error_code(report, :errNoRootsLatestSubmission)
            add_error_code(report, :errRunningReport, ["sub.roots()", e.class, e.message])
          end
        end

        # check if metrics has been generated
        metrics = sub.metrics

        if metrics.nil?
          add_error_code(report, :errNoMetricsLatestSubmission)
        else
          begin
            metrics.bring_remaining
            cl = metrics.classes || 0
            prop = metrics.properties || 0

            if cl.to_i + prop.to_i < 10
              add_error_code(report, :errIncorrectMetricsLatestSubmission)
            end
          rescue Exception => e
            add_error_code(report, :errRunningReport, ["metrics.classes", e.class, e.message])
          end
        end

        # Use OntoLex-specific validation if applicable
        if is_ontolex
          @logger.info("Using OntoLex-specific validation for #{ont.acronym}")
          validate_ontolex_search(sub, report, ont.acronym)
        else
          # Use standard class-based validation
          gc = nil

          begin
            gc = good_classes(sub, report)
          rescue Exception => e
            gc = nil
            add_error_code(report, :errRunningReport, ["good_classes()", e.class, e.message])
          end

          if gc&.empty?
            add_error_code(report, :errNoClassesLatestSubmission)
          elsif gc
            delim = " | "
            search_text = gc.join(delim)

            # check for Annotator calls
            ann = Annotator::Models::NcboAnnotator.new(@logger)
            ann_response = ann.annotate(search_text, { ontologies: [ont.acronym] })

            if ann_response.length < gc.length
              ann_search_terms = []

              gc.each do |cls|
                ann_response_term = ann.annotate(cls, { ontologies: [ont.acronym] })
                ann_search_terms << (ann_response_term.empty? ? "<span class='missing_term'>#{cls}</span>" : cls)
              end
              add_error_code(report, :errNoAnnotator, [ann_response.length, ann_search_terms.join(delim)])
            end

            # check for Search calls
            search_resp = LinkedData::Models::Class.search(solr_escape(search_text), search_query_params(ont.acronym))

            if search_resp["response"]["numFound"] < gc.length
              search_search_terms = []

              gc.each do |cls|
                search_response_term = LinkedData::Models::Class.search(solr_escape(cls), search_query_params(ont.acronym))
                search_search_terms << (search_response_term["response"]["numFound"] > 0 ? cls : "<span class='missing_term'>#{cls}</span>")
              end
              add_error_code(report, :errNoSearch, [search_resp["response"]["numFound"], search_search_terms.join(delim)])
            end
          end
        end
        
        ontology_report_date(report, "report_date_updated")
        report
      end

      # New method: Validate OntoLex ontologies using lexical forms
      def validate_ontolex_search(submission, report, acronym)
        forms_size = 10
        good_forms = []
        
        begin
          # Get sample lexical forms from the ontology
          page_num = 1
          page_size = 1000
          
          paging = LinkedData::Models::LexicalForm.in(submission)
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
            @logger.error("Error during OntoLex form paging - #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
            add_error_code(report, :errRunningReport, ["validate_ontolex_search", e.class, e.message])
            return
          end
          
        rescue Exception => e
          @logger.error("Error getting OntoLex forms - #{e.class}: #{e.message}")
          add_error_code(report, :errRunningReport, ["validate_ontolex_search_forms", e.class, e.message])
          return
        end
        
        if good_forms.empty?
          add_error_code(report, :errNoClassesLatestSubmission)
          return
        end
        
        delim = " | "
        search_text = good_forms.join(delim)
        
        # Check for Annotator calls with OntoLex forms
        begin
          ann = Annotator::Models::NcboAnnotator.new(@logger)
          ann_response = ann.annotate(search_text, { ontologies: [acronym] })
          
          if ann_response.length < good_forms.length
            ann_search_terms = []
            
            good_forms.each do |form_text|
              ann_response_term = ann.annotate(form_text, { ontologies: [acronym] })
              ann_search_terms << (ann_response_term.empty? ? "<span class='missing_term'>#{form_text}</span>" : form_text)
            end
            add_error_code(report, :errNoAnnotator, [ann_response.length, ann_search_terms.join(delim)])
          end
        rescue Exception => e
          @logger.error("Error during OntoLex annotator validation - #{e.class}: #{e.message}")
          add_error_code(report, :errRunningReport, ["validate_ontolex_annotator", e.class, e.message])
        end
        
        # Check for Search calls with OntoLex forms
        begin
          # Use lexical search for OntoLex
          search_resp = LinkedData::Models::LexicalForm.search(
            solr_escape(search_text),
            search_query_params(acronym)
          )
          
          if search_resp["response"]["numFound"] < good_forms.length
            search_search_terms = []
            
            good_forms.each do |form_text|
              search_response_term = LinkedData::Models::LexicalForm.search(
                solr_escape(form_text),
                search_query_params(acronym)
              )
              search_search_terms << (search_response_term["response"]["numFound"] > 0 ? form_text : "<span class='missing_term'>#{form_text}</span>")
            end
            add_error_code(report, :errNoSearch, [search_resp["response"]["numFound"], search_search_terms.join(delim)])
          end
        rescue Exception => e
          @logger.error("Error during OntoLex search validation - #{e.class}: #{e.message}")
          add_error_code(report, :errRunningReport, ["validate_ontolex_search", e.class, e.message])
        end
      end
      
    end
  end
end

puts "[OntoLex Extension] Completed loading ncbo_cron_ontologies_report_extension.rb"
