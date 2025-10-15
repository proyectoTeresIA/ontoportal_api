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
      when 'lexical_entry', 'lexical_entries', 'lexical'
        return process_lexical_search(params, text)
      else
        error 400, "Unsupported resource_type '#{resource_type}'. Use 'class' or 'lexical_entry'."
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

    # Minimal OntoLex lexical entry search. If a dedicated Solr index is present
    # and LinkedData::Models::OntoLex::LexicalEntry responds to :search, we use it.
    # Otherwise, we fallback to in-memory filtering of entries' forms.writtenRep for the requested ontology.
    def process_lexical_search(params, text)
      set_page_params(params)

      # Try Solr first if available
      if LinkedData::Models::OntoLex::LexicalEntry.respond_to?(:search)
        # Reuse existing query builder for pagination params; lexical-specific qf should be handled by backend
        query = text.to_s.strip.empty? ? '*:*' : text
        resp = LinkedData::Models::OntoLex::LexicalEntry.search(query, params)
        total_found = resp["response"]["numFound"]

        docs = []
        resp["response"]["docs"].each do |doc|
          d = doc.symbolize_keys
          resource_id = d[:resource_id]
          d.delete :resource_id
          d[:id] = resource_id
          ontology_uri = d[:ontologyId].sub(/\/submissions\/.*/, "") rescue nil
          next unless ontology_uri
          ontology = LinkedData::Models::Ontology.read_only(id: ontology_uri, acronym: d[:submissionAcronym])
          submission = LinkedData::Models::OntologySubmission.read_only(id: d[:ontologyId], ontology: ontology)
          d[:submission] = submission
          d[:properties] = MultiJson.load(d.delete(:propertyRaw)) if include_param_contains?(:properties)
          instance = LinkedData::Models::OntoLex::LexicalEntry.read_only(d)
          docs << instance
        end
        page = page_object(docs, total_found)
        return reply 200, page
      end

      # Fallback: require a single ontology scope for performance and perform a simple substring match on forms
      onts = restricted_ontologies(params)
      sub = nil
      if onts.length == 1
        ont = onts.first
        sub = ont.latest_submission(status: [:RDF])
      end

      page, size = page_params(params)
      q = (text || '').strip.downcase
      include_attrs = [:form]
      entries = []
      if sub
        entries = LinkedData::Models::OntoLex::LexicalEntry.in(sub).include(include_attrs).page(page, size).all
      else
        # As a last resort (e.g., in tests), search across all entries
        entries = LinkedData::Models::OntoLex::LexicalEntry.where.include(include_attrs).all
      end

      # Simple filter by writtenRep of forms (case-insensitive substring). If q is empty, return page unchanged.
      if !q.empty?
        entries.select! do |e|
          next false if e.form.nil?
          e.form.any? do |f|
            reps = f.respond_to?(:writtenRep) ? Array(f.writtenRep) : []
            reps.any? { |r| r.to_s.downcase.include?(q) }
          end
        end
      end

      # Sort by first match alphabetically for determinism
      entries.sort_by! do |e|
        lab = e.form&.first&.writtenRep
        Array(lab).first.to_s.downcase
      end

      page_obj = page_object(entries, entries.length)
      reply 200, page_obj
    end

  end
end
