require 'cgi'
class LexicalConceptsController < ApplicationController
  helpers OntolexSearchHelper

  namespace "/ontologies/:ontology/lexical_concepts" do

    get do
      includes_param_check(LinkedData::Models::OntoLex::LexicalConcept)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalConcept, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Load only minimal attributes needed for sorting/filtering
      minimal_attrs = [:prefLabel, :definition]
      all_items = LinkedData::Models::OntoLex::LexicalConcept.in(submission).include(*minimal_attrs).all
      
      items_with_labels = all_items.map do |item|
        label = get_concept_label(item)
        { id: item.id, label: label, label_lower: label.downcase }
      end
      
      # Filter and sort by relevance (prefix matches first, then position-based)
      items_with_labels = filter_and_sort_by_relevance(items_with_labels, search_query)
      
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
      
      # Only load full attributes for the paginated items
      if page_items.any?
        page_ids = page_items.map { |item| item[:id] }
        full_ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load([:all])
        items = LinkedData::Models::OntoLex::LexicalConcept.list_for_ids(submission, page_ids, full_ld)
        
        # Preserve sort order from page_items
        id_to_item = items.index_by { |i| i.id.to_s }
        items = page_ids.map { |id| id_to_item[id.to_s] }.compact
      else
        items = []
      end
      
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
      val = val.sub(/^(https?):[\/]+/, '\1://')
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
