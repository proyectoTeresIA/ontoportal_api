require 'cgi'

class TerminologicalEntriesController < ApplicationController

  namespace "/ontologies/:ontology/terminological_entries" do

    # Optimized list endpoint: Returns lexical entries with their forms' writtenReps
    # This reduces multiple requests to a single call
    get do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Get ALL entries first for global sorting
      ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:language, :form])
      all_entries = LinkedData::Models::OntoLex::LexicalEntry.list_in_submission(submission, 1, 100000, ld)
      
      # Enrich all entries with form writtenReps
      all_enriched = all_entries.map { |entry| enrich_entry(entry, submission) }
      
      # Apply search filter if present
      unless search_query.empty?
        all_enriched.select! do |entry_hash|
          reps = entry_hash['writtenReps'] || []
          reps.any? { |rep| rep.to_s.downcase.include?(search_query) }
        end
      end
      
      # Sort ALL items alphabetically (global sort)
      all_enriched.sort_by! { |e| (e['writtenReps']&.first || e['@id'].to_s.split('/').last).to_s.downcase }
      
      # Now apply pagination on sorted results
      total = all_enriched.length
      start_idx = (page - 1) * size
      enriched_entries = all_enriched.slice(start_idx, size) || []
      
      reply page_object(enriched_entries, total)
    end

    # Optimized single entry endpoint: Returns full entry details with all related entities
    get '/*' do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      # Get entry ID from splat
      id = if params['splat'].is_a?(Array)
             params['splat'].first
           else
             params['splat'] || params[:splat]
           end
      
      halt 404, 'Entry id not provided' if id.nil? || id.empty?
      id = normalize_iri(id)
      
      # Load the lexical entry with all attributes
      ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:all])
      entry = LinkedData::Models::OntoLex::LexicalEntry.list_for_ids(submission, [id], ld).first
      error 404, "Entry not found: #{id}" if entry.nil?
      
      # Use to_json and parse back to get a clean hash without empty objects
      entry_json = entry.to_json
      entry_hash = JSON.parse(entry_json)
      
      # Load and enrich forms with all their data
      if entry.form && !entry.form.empty?
        form_ids = Array(entry.form)
        forms_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:all])
        forms = LinkedData::Models::OntoLex::Form.list_for_ids(submission, form_ids, forms_ld)
        entry_hash['loadedForms'] = forms.map { |f| JSON.parse(f.to_json) }
      end
      
      # Load and enrich senses
      if entry.sense && !entry.sense.empty?
        sense_ids = Array(entry.sense)
        senses_ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load([:all])
        senses = LinkedData::Models::OntoLex::LexicalSense.list_for_ids(submission, sense_ids, senses_ld)
        
        # Enrich senses with related lexical entries for translations/synonyms
        entry_hash['loadedSenses'] = senses.map do |sense|
          sense_hash = JSON.parse(sense.to_json)
          
          # Load related entries (translations, synonyms, etc.) with their writtenReps
          [:translation, :synonym, :antonym].each do |rel_type|
            if sense.respond_to?(rel_type) && sense.send(rel_type)
              rel_sense_ids = Array(sense.send(rel_type))
              next if rel_sense_ids.empty?
              
              # Load related senses
              rel_senses_ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load([:isSenseOf])
              rel_senses = LinkedData::Models::OntoLex::LexicalSense.list_for_ids(submission, rel_sense_ids, rel_senses_ld)
              
              # For each related sense, load its entry and forms to get writtenReps
              sense_hash["loaded_#{rel_type}"] = rel_senses.map do |rel_sense|
                rel_sense_hash = JSON.parse(rel_sense.to_json)
                
                if rel_sense.isSenseOf
                  entry_id = rel_sense.isSenseOf
                  rel_entry_ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:form])
                  rel_entry = LinkedData::Models::OntoLex::LexicalEntry.list_for_ids(submission, [entry_id], rel_entry_ld).first
                  
                  if rel_entry && rel_entry.form
                    form_ids = Array(rel_entry.form)
                    forms_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:writtenRep])
                    forms = LinkedData::Models::OntoLex::Form.list_for_ids(submission, form_ids, forms_ld)
                    rel_sense_hash['writtenReps'] = forms.map { |f| f.writtenRep }.compact
                    rel_sense_hash['entryId'] = entry_id.to_s
                  end
                end
                
                rel_sense_hash
              end
            end
          end
          
          sense_hash
        end
      end
      
      # Load evoked concept if present
      if entry.evokes
        concept_id = entry.evokes
        concept_ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load([:all])
        concept = LinkedData::Models::OntoLex::LexicalConcept.list_for_ids(submission, [concept_id], concept_ld).first
        entry_hash['loadedConcept'] = JSON.parse(concept.to_json) if concept
      end
      
      reply entry_hash
    end

    private
    
    # Enrich a lexical entry with form writtenReps
    def enrich_entry(entry, submission)
      entry_hash = {
        '@id' => entry.id.to_s,
        'id' => entry.id.to_s
      }
      
      # Add language if loaded
      entry_hash['language'] = entry.language.to_s if entry.language
      
      # Add form URIs if loaded
      if entry.form && !entry.form.empty?
        form_ids = Array(entry.form)
        entry_hash['form'] = form_ids.map(&:to_s)
        
        # Load forms and extract writtenReps
        forms_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:writtenRep])
        forms = LinkedData::Models::OntoLex::Form.list_for_ids(submission, form_ids, forms_ld)
        entry_hash['writtenReps'] = forms.map { |f| f.writtenRep }.compact
      else
        entry_hash['form'] = []
        entry_hash['writtenReps'] = []
      end
      
      entry_hash
    end
    
    def normalize_iri(raw)
      val = raw.to_s
      # decode up to twice
      2.times do
        begin
          decoded = CGI.unescape(val)
          val = decoded if decoded && decoded != val
        rescue StandardError
          break
        end
      end
      # fix scheme having one slash e.g., http:/example → http://example
      val = val.sub(/^(https?):\/(?!\/)/, '\1://')
      val
    end
  end
end
