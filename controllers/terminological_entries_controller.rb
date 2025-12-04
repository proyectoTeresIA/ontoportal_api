require 'cgi'

class TerminologicalEntriesController < ApplicationController

  namespace "/ontologies/:ontology/terminological_entries" do

    get do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Load entries with form references
      minimal_attrs = [:form]
      all_entries = LinkedData::Models::OntoLex::LexicalEntry.in(submission).include(*minimal_attrs).all
      
      # Collect ALL form IDs for batch loading
      all_form_ids = all_entries.flat_map { |e| Array(e.form) }.compact.uniq
      
      # Batch load ALL forms with writtenRep in a single query
      form_reps = {}
      if all_form_ids.any?
        forms = LinkedData::Models::OntoLex::Form.in(submission).include(:writtenRep).all
        forms.each { |f| form_reps[f.id.to_s] = f.writtenRep }
      end
      
      # Build sort/filter data using writtenReps from forms
      items_with_labels = all_entries.map do |entry|
        form_ids = Array(entry.form)
        # Get first writtenRep from forms as label
        label = form_ids.map { |fid| form_reps[fid.to_s] }.compact.first
        label ||= entry.id.to_s.split('/').last
        label = label.to_s
        { id: entry.id, form_ids: form_ids, label: label, label_lower: label.downcase }
      end
      
      unless search_query.empty?
        items_with_labels.select! { |item| item[:label_lower].include?(search_query) }
      end
      
      # Global sort
      items_with_labels.sort_by! { |item| item[:label_lower] }
      
      # Pagination
      total = items_with_labels.length
      
      # If find_id parameter is provided, calculate which page contains that item
      find_id = params['find_id']
      if find_id && !find_id.empty?
        find_id = normalize_iri(find_id)
        item_index = items_with_labels.find_index { |item| item[:id].to_s == find_id }
        if item_index
          page = (item_index / size) + 1
          params['page'] = page.to_s
        end
      end
      
      start_idx = (page - 1) * size
      page_items = items_with_labels.slice(start_idx, size) || []
      
      # Build enriched entries preserving sort order
      enriched_entries = page_items.map do |item|
        reps = item[:form_ids].map { |fid| form_reps[fid.to_s] }.compact
        {
          '@id' => item[:id].to_s,
          'id' => item[:id].to_s,
          'form' => item[:form_ids].map(&:to_s),
          'writtenReps' => reps
        }
      end
      
      reply page_object(enriched_entries, total)
    end

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
              
              # For each related sense, load its entry and forms to get writtenReps and language
              sense_hash["loaded_#{rel_type}"] = rel_senses.map do |rel_sense|
                rel_sense_hash = JSON.parse(rel_sense.to_json)
                
                if rel_sense.isSenseOf
                  entry_id = rel_sense.isSenseOf
                  rel_entry_ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:form, :language])
                  rel_entry = LinkedData::Models::OntoLex::LexicalEntry.list_for_ids(submission, [entry_id], rel_entry_ld).first
                  
                  if rel_entry && rel_entry.form
                    form_ids = Array(rel_entry.form)
                    forms_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:writtenRep])
                    forms = LinkedData::Models::OntoLex::Form.list_for_ids(submission, form_ids, forms_ld)
                    rel_sense_hash['writtenReps'] = forms.map { |f| f.writtenRep }.compact
                  end
                  rel_sense_hash['language'] = rel_entry.language.to_s if rel_entry.language
                  rel_sense_hash['entryId'] = entry_id.to_s
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
      val = val.sub(/^(https?):[\/]+/, '\1://')
      val
    end
  end
end
