require "cgi"

class LexicalSensesController < ApplicationController
  namespace "/ontologies/:ontology/lexical_senses" do
    get do
      includes_param_check(LinkedData::Models::OntoLex::LexicalSense)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalSense, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Get ALL items first for global sorting
      ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load([:all])
      all_items = LinkedData::Models::OntoLex::LexicalSense.list_in_submission(submission, 1, 100000, ld)
      
      # Ensure computed attributes
      all_items.each { |it| it.ensure_computed rescue nil }
      
      # Build a cache of labels
      label_cache = {}
      all_items.each do |item|
        label_cache[item.id.to_s] = get_sense_label(item).downcase
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
  end
end
