require 'multi_json'
require 'cgi'

class SearchController < ApplicationController
  namespace "/search" do
    # execute a search query
    get do
      process_search()
    end

    post do
      process_search()
    end

    private

    def process_search(params=nil)
      params ||= @params
      text = params["q"]

      # Unified search endpoint: support classes (default) and OntoLex via resource_type
      resource_type = (params['resource_type'] || params['type'] || 'class').to_s
      case resource_type
      when 'class', 'classes'
        return process_class_search(params, text)
      when 'form', 'forms', 'lexical'
        return process_lexical_search(params, text)
      else
        error 400, "Unsupported resource_type '#{resource_type}'. Use 'class' or 'form'."
      end
    end

    def process_class_search(params, text)
      # existing class search path
      query = get_term_search_query(text, params)
      set_page_params(params)

      query = get_term_search_query(text, params)
      # puts "Edismax query: #{query}, params: #{params}"
      set_page_params(params)

      docs = Array.new
      resp = LinkedData::Models::Class.search(query, params)
      total_found = resp["response"]["numFound"]
      add_matched_fields(resp, Sinatra::Helpers::SearchHelper::MATCH_TYPE_PREFLABEL)
      ontology_rank = LinkedData::Models::Ontology.rank

      resp["response"]["docs"].each do |doc|
        doc = doc.symbolize_keys
        # NCBO-974
        doc[:matchType] = resp["match_types"][doc[:id]]
        resource_id = doc[:resource_id]
        doc.delete :resource_id
        doc[:id] = resource_id
        # TODO: The `rescue next` on the following line shouldn't be here
        # However, at some point we didn't store the ontologyId in the index
        # and these records haven't been cleared out so this is getting skipped
        ontology_uri = doc[:ontologyId].sub(/\/submissions\/.*/, "") rescue next
        ontology = LinkedData::Models::Ontology.read_only(id: ontology_uri, acronym: doc[:submissionAcronym])
        submission = LinkedData::Models::OntologySubmission.read_only(id: doc[:ontologyId], ontology: ontology)
        doc[:submission] = submission
        doc[:ontology_rank] = (ontology_rank[doc[:submissionAcronym]] && !ontology_rank[doc[:submissionAcronym]].empty?) ? ontology_rank[doc[:submissionAcronym]][:normalizedScore] : 0.0
        doc[:properties] = MultiJson.load(doc.delete(:propertyRaw)) if include_param_contains?(:properties)
        instance = doc[:provisional] ? LinkedData::Models::ProvisionalClass.read_only(doc) : LinkedData::Models::Class.read_only(doc)
        filter_language_attributes(params, instance)
        docs.push(instance)
      end

      unless params['sort']
        if !text.nil? && text[-1] == '*'
          docs.sort! {|a, b| [b[:score], a[:prefLabelExact].downcase, b[:ontology_rank]] <=> [a[:score], b[:prefLabelExact].downcase, a[:ontology_rank]]}
        else
          docs.sort! {|a, b| [b[:score], b[:ontology_rank]] <=> [a[:score], a[:ontology_rank]]}
        end
      end

      #need to return a Page object
      page = page_object(docs, total_found)

      reply 200, page
    end

    # OntoLex lexical entry search with full Solr support
    # Supports language filtering, subject/domain filtering, and all standard search features
    def process_lexical_search(params, text)
      params["_requested_ontologies"] = params[Sinatra::Helpers::SearchHelper::ONTOLOGIES_PARAM]

      direct_page = lexical_search_direct_page(params, text)
      return reply 200, direct_page if direct_page

      set_page_params(params)

      # Try Solr first if available
      if LinkedData::Models::OntoLex::Form.respond_to?(:search)
        # Build lexical-specific query
        query = get_lexical_search_query(text, params)
        # Apply default ontology access/existence filtering (same behavior as class search).
        # This prevents stale lexical index documents from deleted ontologies from leaking.
        allowed_acronyms = restricted_ontologies_to_acronyms(params)
        allowed_filter = get_quoted_field_query_param(allowed_acronyms, "OR", "submissionAcronym")
        if params["fq"].nil? || params["fq"].empty?
          params["fq"] = allowed_filter
        else
          params["fq"] = "(#{params["fq"]}) AND #{allowed_filter}"
        end
        # puts "Lexical search query: #{query}, params: #{params}"
        
        resp = LinkedData::Models::OntoLex::Form.search(query, params)
        total_found = resp["response"]["numFound"]
        if total_found.to_i == 0
          # In local/dev environments the Solr lexical core can be empty even when
          # OntoLex data exists in RDF. Fall back to direct store search.
          return reply 200, lexical_search_fallback_page(params, text)
        end
        add_matched_fields(resp, Sinatra::Helpers::SearchHelper::MATCH_TYPE_PREFLABEL)
        
        docs = []
        resp["response"]["docs"].each do |doc|
          d = doc.symbolize_keys
          # Add match type from highlighting
          d[:matchType] = resp["match_types"][d[:id]] if resp["match_types"]
          
          resource_id = d[:resource_id]
          d.delete :resource_id
          d[:id] = resource_id
          
          ontology_uri = d[:ontologyId].sub(/\/submissions\/.*/, "") rescue nil
          next unless ontology_uri
          
          ontology = LinkedData::Models::Ontology.read_only(id: ontology_uri, acronym: d[:submissionAcronym])
          submission = LinkedData::Models::OntologySubmission.read_only(id: d[:ontologyId], ontology: ontology)
          d[:submission] = submission
          d[:properties] = MultiJson.load(d.delete(:propertyRaw)) if include_param_contains?(:properties)
          
          # Remove Solr-specific suggest fields but keep enriched fields for serialization
          d.delete(:writtenRepExact)
          d.delete(:lemmaExact)
          d.delete(:lemmaSuggestEdge)
          d.delete(:lemmaSuggestNgram)
          d.delete(:writtenRepSuggestEdge)
          d.delete(:writtenRepSuggestNgram)
          
          instance = LinkedData::Models::OntoLex::Form.read_only(d)
          filter_language_attributes(params, instance)
          docs << instance
        end
        
        # Sort by score (already sorted by Solr, but ensure consistency)
        unless params['sort']
          docs.sort! { |a, b| b[:score] <=> a[:score] }
        end
        
        page = page_object(docs, total_found)
        return reply 200, page
      end

      # Fallback: require a single ontology scope for performance and perform a simple substring match on forms
      onts = restricted_ontologies(params)
      sub = nil
      if onts.length == 1
        ont = onts.first
        ont.bring(:submissions) if ont.respond_to?(:bring?) && ont.bring?(:submissions)
        sub = ont.latest_submission(status: :any)
      end

      reply 200, lexical_search_fallback_page(params, text)
    end

    def lexical_search_direct_page(params, text)
      requested_ontologies = params[Sinatra::Helpers::SearchHelper::ONTOLOGIES_PARAM].to_s
      acronyms = requested_ontologies.split(',').map(&:strip).reject(&:empty?)

      if acronyms.empty?
        restricted = restricted_ontologies(params)
        acronyms = restricted.map { |o| o.respond_to?(:acronym) ? o.acronym.to_s : nil }.compact.uniq
      end

      return nil unless acronyms.length == 1

      ont = LinkedData::Models::Ontology.find(acronyms.first).first
      ont ||= LinkedData::Models::Ontology.find_by_acronym(acronyms.first).first
      return nil unless ont

      ont.bring(:submissions) if ont.respond_to?(:bring?) && ont.bring?(:submissions)
      submission = ont.latest_submission(status: [:RDF])
      submission ||= ont.latest_submission(status: :any)
      return nil unless submission

      page, size = page_params(params)
      q = (text || '').strip.downcase
      all_items = LinkedData::Models::OntoLex::Form.in(submission).include(:writtenRep).all

      items_with_labels = all_items.map do |item|
        label = (item.writtenRep || item.id.to_s.split('/').last).to_s
        { id: item.id, label: label, label_lower: label.downcase }
      end

      if !q.empty?
        items_with_labels.select! { |item| item[:label_lower].include?(q) }
      end

      items_with_labels.sort_by! { |item| item[:label_lower] }
      total = items_with_labels.length
      start_idx = (page - 1) * size
      page_items = items_with_labels.slice(start_idx, size) || []

      if page_items.any?
        page_ids = page_items.map { |item| item[:id] }
        full_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:all])
        items = LinkedData::Models::OntoLex::Form.list_for_ids(submission, page_ids, full_ld)
        id_to_item = items.index_by { |i| i.id.to_s }
        items = page_ids.map { |id| id_to_item[id.to_s] }.compact
        items.each { |it| it.ensure_computed rescue nil }
      else
        items = []
      end

      page_object(items, total)
    rescue StandardError => e
      Log.add :error, "Lexical direct search fallback failed: #{e.class}: #{e.message}"
      nil
    end

    def lexical_search_fallback_page(params, text)
      requested_ontologies = params["_requested_ontologies"].to_s
      onts = restricted_ontologies(params)
      sub = nil
      if !requested_ontologies.empty?
        acronyms = requested_ontologies.split(',').map(&:strip).reject(&:empty?)
        if acronyms.length == 1
          ont = LinkedData::Models::Ontology.find(acronyms.first).first
          ont ||= LinkedData::Models::Ontology.find_by_acronym(acronyms.first).first
          if ont
            ont.bring(:submissions) if ont.respond_to?(:bring?) && ont.bring?(:submissions)
            sub = ont.latest_submission(status: :any)
          end
        end
      elsif onts.length == 1
        ont = onts.first
        ont.bring(:submissions) if ont.respond_to?(:bring?) && ont.bring?(:submissions)
        sub = ont.latest_submission(status: :any)
      end

      page, size = page_params(params)
      q = (text || '').strip.downcase
      include_attrs = [:writtenRep, :language]
      forms = []
      if sub
        # Load all forms first, then filter and paginate. Paging before filtering
        # can miss matches that are not in the first page chunk.
        forms = LinkedData::Models::OntoLex::Form.in(sub).include(include_attrs).all
      else
        # As a last resort (e.g., in tests), search across all forms
        forms = LinkedData::Models::OntoLex::Form.where.include(include_attrs).all
      end

      # Simple filter by writtenRep (case-insensitive substring). If q is empty, return page unchanged.
      if !q.empty?
        forms.select! do |f|
          reps = f.respond_to?(:writtenRep) ? Array(f.writtenRep) : []
          reps.any? { |r| r.to_s.downcase.include?(q) }
        end
      end

      # Sort by writtenRep alphabetically for determinism
      forms.sort_by! do |f|
        Array(f.writtenRep).first.to_s.downcase
      end

      total = forms.length
      start_idx = (page - 1) * size
      forms_page = forms.slice(start_idx, size) || []

      page_object(forms_page, total)
    end

  end
end
