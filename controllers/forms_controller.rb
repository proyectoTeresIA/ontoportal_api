class FormsController < ApplicationController
  helpers OntolexSearchHelper

  namespace "/ontologies/:ontology/forms" do

    get do
      includes_param_check(LinkedData::Models::OntoLex::Form)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::Form, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Load only minimal attributes needed for sorting/filtering
      minimal_attrs = [:writtenRep]
      all_items = LinkedData::Models::OntoLex::Form.in(submission).include(*minimal_attrs).all
      
      # Build sort/filter data from minimal loaded attributes
      items_with_labels = all_items.map do |item|
        label = (item.writtenRep || item.id.to_s.split('/').last).to_s
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
        full_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:all])
        items = LinkedData::Models::OntoLex::Form.list_for_ids(submission, page_ids, full_ld)
        
        # Preserve sort order from page_items
        id_to_item = items.index_by { |i| i.id.to_s }
        items = page_ids.map { |id| id_to_item[id.to_s] }.compact
        
        items.each { |it| it.ensure_computed rescue nil }
      else
        items = []
      end
      
      reply page_object(items, total)
    end

    get '/*' do
      includes_param_check(LinkedData::Models::OntoLex::Form)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::Form, [ont.acronym])

  ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:all])
  id = params[:splat].is_a?(Array) ? params[:splat].first : params[:splat]
  id = normalize_iri(id)
  # Always build enriched read_only using the same logic as list for parity
  form = LinkedData::Models::OntoLex::Form.list_for_ids(submission, [id], ld).first
  error 404, "Form not found: #{id}" if form.nil?
  form.ensure_computed rescue nil
  reply form
    end

    private
    def normalize_iri(raw)
      val = raw.to_s
      val = val.sub(/^(https?):[\/]+/, '\1://')
      val
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
