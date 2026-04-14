require 'cgi'

class TerminologicalEntriesController < ApplicationController
  helpers OntolexSearchHelper

  namespace "/ontologies/:ontology/terminological_entries" do

    get do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Load entries with form references and language
      minimal_attrs = [:form, :language]
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
        language = entry.language ? entry.language.to_s : nil
        { id: entry.id, form_ids: form_ids, label: label, label_lower: label.downcase, language: language }
      end
      
      # Filter and sort by relevance (prefix matches first, then position-based)
      items_with_labels = filter_and_sort_by_relevance(items_with_labels, search_query)
      
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
        entry_hash = {
          '@id' => item[:id].to_s,
          'id' => item[:id].to_s,
          'form' => item[:form_ids].map(&:to_s),
          'writtenReps' => reps
        }
        entry_hash['language'] = item[:language] if item[:language]
        entry_hash
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
        if concept
          concept_hash = JSON.parse(concept.to_json)
          concept_hash['inScheme'] = expand_in_scheme_values(concept_hash['inScheme'], submission)
          entry_hash['loadedConcept'] = concept_hash

          source_summary = extract_source_summary_from_concept(concept_hash)
          entry_hash['sourceResource'] = source_summary if source_summary
        end
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

    def expand_in_scheme_values(in_scheme_values, submission)
      normalize_to_array(in_scheme_values).map do |scheme|
        scheme_uri = extract_uri_value(scheme)
        next scheme unless scheme_uri && !scheme_uri.empty?

        LinkedData::Models::OntoLex::LexicalConcept.expand_in_scheme_for_concept(scheme_uri, submission)
      rescue StandardError
        scheme
      end.compact
    end

    def extract_uri_value(value)
      return nil if value.nil?
      return value.to_s if value.is_a?(String)
      return value.id.to_s if value.respond_to?(:id) && value.id

      if value.is_a?(Array)
        return value[1].to_s if value.length == 2 && value[0].to_s == 'uri'
        return extract_uri_value(value.first)
      end

      if value.is_a?(Hash)
        return value['@id'] if value['@id']
        return value['id'] if value['id']
        return value['uri'] if value['uri']
      end

      value.respond_to?(:to_s) ? value.to_s : nil
    end

    def normalize_to_array(value)
      return [] if value.nil?
      return value if value.is_a?(Array)

      [value]
    end

    def extract_source_summary_from_concept(concept_hash)
      return nil unless concept_hash.is_a?(Hash)

      in_schemes = Array(concept_hash['inScheme'])
      source_obj = in_schemes.map do |scheme|
        scheme.is_a?(Hash) ? scheme['source'] : nil
      end.compact.first

      return nil unless source_obj

      if source_obj.is_a?(Hash)
        summary = {
          '@id' => source_obj['@id'] || source_obj['id']
        }
        summary['resourceName'] = source_obj['resourceName'] if source_obj['resourceName']
        summary['url'] = source_obj['url'] if source_obj['url']
        summary['uri'] = source_obj['uri'] if source_obj['uri']
        summary['resourceCreator'] = source_obj['resourceCreator'] if source_obj['resourceCreator']
        summary['language'] = source_obj['language'] if source_obj['language']
        summary['domain'] = source_obj['domain'] if source_obj['domain']
        return summary
      end

      { '@id' => source_obj.to_s }
    end
  end
end
