require "cgi"

class LexicalSensesController < ApplicationController
  namespace "/ontologies/:ontology/lexical_senses" do
    get do
      includes_param_check(LinkedData::Models::OntoLex::LexicalSense)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalSense, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Load only minimal attributes needed for sorting/filtering
      minimal_attrs = [:definition]
      all_items = LinkedData::Models::OntoLex::LexicalSense.in(submission).include(*minimal_attrs).all
      
      # Build sort/filter data from minimal loaded attributes
      items_with_labels = all_items.map do |item|
        label = (item.definition || item.id.to_s.split('/').last).to_s
        { id: item.id, label: label, label_lower: label.downcase }
      end
      
      # Apply search filter if present
      unless search_query.empty?
        items_with_labels.select! { |item| item[:label_lower].include?(search_query) }
      end
      
      # Sort
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
      
      # Only load full attributes for the paginated items
      if page_items.any?
        page_ids = page_items.map { |item| item[:id] }
        items = LinkedData::Models::OntoLex::LexicalSense.list_for_ids(submission, page_ids)
        
        # Preserve sort order from page_items
        id_to_item = items.index_by { |i| i.id.to_s }
        items = page_ids.map { |id| id_to_item[id.to_s] }.compact
        
        items.each { |it| it.ensure_computed rescue nil }
      else
        items = []
      end
      
      reply page_object(items, total)
    end

    get "/*" do
      includes_param_check(LinkedData::Models::OntoLex::LexicalSense)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalSense, [ont.acronym])

      id = params[:splat].is_a?(Array) ? params[:splat].first : params[:splat]
      id = normalize_iri(id)
      
      # Always use enriched read_only built with the same logic used by the list endpoint
      sense = LinkedData::Models::OntoLex::LexicalSense.list_for_ids(submission, [id]).first
      error 404, "LexicalSense not found: #{id}" if sense.nil?
      sense.ensure_computed rescue nil
      reply sense
    end

    private

    def includes_param_check(klass)
      if includes_param && !includes_param.empty?
        allowed = klass.attributes + [:all]
        leftover = includes_param - allowed
        error(400, "Invalid include params: #{leftover.join(", ")}") unless leftover.empty?
      end
    end

    # Get a display label for a lexical sense
    def get_sense_label(sense)
      # Try definition first
      if sense.respond_to?(:definition) && sense.definition && !sense.definition.to_s.empty?
        return sense.definition.to_s
      end
      
      # Try example
      if sense.respond_to?(:example) && sense.example && !sense.example.to_s.empty?
        return sense.example.to_s
      end
      
      # Fallback to last part of ID
      sense.id.to_s.split('/').last
    end

    def normalize_iri(raw)
      val = raw.to_s
      val = val.sub(/^(https?):[\/]+/, '\1://')
      val
    end
  end
end
