require 'cgi'
class LexicalConceptsController < ApplicationController

  namespace "/ontologies/:ontology/lexical_concepts" do

    get do
      includes_param_check(LinkedData::Models::OntoLex::LexicalConcept)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalConcept, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Get ALL items first for global sorting
      ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load([:all])
      all_items = LinkedData::Models::OntoLex::LexicalConcept.list_in_submission(submission, 1, 100000, ld)
      
      # Build a cache of labels
      label_cache = {}
      all_items.each do |item|
        label_cache[item.id.to_s] = get_concept_label(item).downcase
      end
      
      # Apply search filter if present
      unless search_query.empty?
        all_items.select! do |item|
          label_cache[item.id.to_s].include?(search_query)
        end
      end
      
      # Sort ALL items alphabetically (global sort)
      all_items.sort_by! { |item| label_cache[item.id.to_s] }
      
      # Now apply pagination on sorted results
      total = all_items.length
      start_idx = (page - 1) * size
      items = all_items.slice(start_idx, size) || []
      
      reply page_object(items, total)
    end

    get '/*' do
      includes_param_check(LinkedData::Models::OntoLex::LexicalConcept)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalConcept, [ont.acronym])

  # Load enriched read_only using the same logic as list for parity
  ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load([:all])
      id = params[:splat].is_a?(Array) ? params[:splat].first : params[:splat]
      id = normalize_iri(id)
      rid = begin
        RDF::URI(id.to_s)
      rescue StandardError
        nil
      end
  error 404, "LexicalConcept not found: #{id}" unless rid && rid.to_s.start_with?("http")
      concept = LinkedData::Models::OntoLex::LexicalConcept.list_for_ids(submission, [rid], ld).first
      error 404, "LexicalConcept not found: #{id}" unless concept
      reply concept
    end

    private
    def normalize_iri(raw)
      val = raw.to_s
      2.times do
        begin
          decoded = CGI.unescape(val)
          val = decoded if decoded && decoded != val
        rescue StandardError
          break
        end
      end
      val = val.sub(/^(https?):\/(?!\/)/, '\1://')
      val
    end

    # Get a display label for a lexical concept
    def get_concept_label(concept)
      # Try to get label from definition
      if concept.respond_to?(:definition) && concept.definition
        defs = Array(concept.definition)
        defs.each do |d|
          if d.is_a?(Hash)
            return d['label'].to_s if d['label'] && !d['label'].to_s.empty?
            return d['value'].to_s if d['value'] && !d['value'].to_s.empty?
          elsif d.respond_to?(:label) && d.label
            return d.label.to_s
          elsif d.respond_to?(:value) && d.value
            return d.value.to_s
          end
        end
      end
      
      # Fallback to last part of ID
      concept.id.to_s.split('/').last
    end

    def includes_param_check(klass)
      if includes_param && !includes_param.empty?
        allowed = klass.attributes + [:all]
        leftover = includes_param - allowed
        error(400, "Invalid include params: #{leftover.join(', ')}") unless leftover.empty?
      end
    end
    end
end
