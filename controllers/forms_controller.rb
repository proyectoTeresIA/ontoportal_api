class FormsController < ApplicationController

  namespace "/ontologies/:ontology/forms" do

    get do
      includes_param_check(LinkedData::Models::OntoLex::Form)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::Form, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Get ALL items first for global sorting
      ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:all])
      all_items = LinkedData::Models::OntoLex::Form.list_in_submission(submission, 1, 100000, ld)
      
      # Ensure computed attributes
      all_items.each { |it| it.ensure_computed rescue nil }
      
      # Apply search filter if present
      unless search_query.empty?
        all_items.select! do |item|
          rep = item.writtenRep.to_s.downcase
          rep.include?(search_query)
        end
      end
      
      # Sort ALL items alphabetically (global sort)
      all_items.sort_by! { |item| (item.writtenRep || item.id.to_s.split('/').last).to_s.downcase }
      
      # Now apply pagination on sorted results
      total = all_items.length
      start_idx = (page - 1) * size
      items = all_items.slice(start_idx, size) || []
      
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
      2.times do
        begin
          decoded = CGI.unescape(val)
          val = decoded if decoded && decoded != val
        rescue StandardError
          break
        end
      end
      val = val.sub(/^(https?):\/(?!\/)/, '\\1://')
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
