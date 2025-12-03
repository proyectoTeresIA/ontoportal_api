require 'cgi'
class LexicalEntriesController < ApplicationController

  namespace "/ontologies/:ontology/lexical_entries" do

    # List lexical entries for an ontology submission
    get do
      includes_param_check(LinkedData::Models::OntoLex::LexicalEntry)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      page, size = page_params
      search_query = (params['q'] || '').strip.downcase
      
      # Load only minimal attributes needed for sorting/filtering
      minimal_attrs = [:lemma]
      all_items = LinkedData::Models::OntoLex::LexicalEntry.in(submission).include(*minimal_attrs).all
      
      # Build sort/filter data from minimal loaded attributes
      items_with_labels = all_items.map do |item|
        label = (item.lemma || item.id.to_s.split('/').last).to_s
        { id: item.id, label: label, label_lower: label.downcase }
      end
      
      unless search_query.empty?
        items_with_labels.select! { |item| item[:label_lower].include?(search_query) }
      end
      
      items_with_labels.sort_by! { |item| item[:label_lower] }
      
      total = items_with_labels.length
      start_idx = (page - 1) * size
      page_items = items_with_labels.slice(start_idx, size) || []
      
      # Only load full attributes for the paginated items
      if page_items.any?
        page_ids = page_items.map { |item| item[:id] }
        full_ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:all])
        items = LinkedData::Models::OntoLex::LexicalEntry.list_for_ids(submission, page_ids, full_ld)
        
        # Preserve sort order from page_items
        id_to_item = items.index_by { |i| i.id.to_s }
        items = page_ids.map { |id| id_to_item[id.to_s] }.compact
      else
        items = []
      end
      
      reply page_object(items, total)
    end

    # List senses for a given lexical entry
    get '/*/senses' do
      ont, submission = get_ontology_and_submission
      splat = params['splat'] || params[:splat]
      id = splat.is_a?(Array) ? splat.first : splat
      halt 400, 'Missing LexicalEntry id' if id.nil? || id.empty?
      id = normalize_iri(id)
      ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([])
      entry = LinkedData::Models::OntoLex::LexicalEntry.find(create_rdf_uri(id) || id).in(submission).include(ld).first
      error 404, "LexicalEntry not found: #{id}" if entry.nil?
      senses = Array(entry.sense) || []
      reply senses
    end

    # Get the label (writtenRep) for a lexical entry
    # This is similar to the /ajax/classes/label endpoint for regular ontologies
    get '/*/label' do
      ont, submission = get_ontology_and_submission
      splat = params['splat'] || params[:splat]
      id = splat.is_a?(Array) ? splat.first : splat
      halt 400, 'Missing LexicalEntry id' if id.nil? || id.empty?
      id = normalize_iri(id)
      
      # Query for all the entry's form writtenReps directly from SPARQL
      query = <<-SPARQL
SELECT DISTINCT ?rep
WHERE {
  GRAPH <#{submission.id}> {
    <#{id}> <http://www.w3.org/ns/lemon/ontolex#form> ?form .
    ?form <http://www.w3.org/ns/lemon/ontolex#writtenRep> ?rep .
  }
}
      SPARQL
      
      epr = Goo.sparql_query_client(:main)
      solutions = epr.query(query)
      
      if solutions.length > 0
        label_values = solutions.map { |sol| sol[:rep].to_s }.reject(&:empty?).uniq
        reply({ label: label_values.join(', ') })
      else
        # Fallback: try to extract from ID
        # e.g., "...C1_ca_absorciometre_noun_entry" -> "absorciometre"
        id_parts = id.to_s.split('_')
        label = id.to_s.split('/').last  # default to last part of URI
        
        if id_parts.length >= 3
          lang_idx = id_parts.index { |p| p.length == 2 && p =~ /^[a-z]{2}$/ }
          if lang_idx && id_parts[lang_idx + 1]
            term = id_parts[lang_idx + 1]
            label = term unless term =~ /^(noun|verb|adj|entry|form)$/
          end
        end
        
        reply({ label: label })
      end
    end

    # Get mappings for a lexical entry
    # Must be before the wildcard /* route
    get '/*/mappings' do
      ont, submission = get_ontology_and_submission
      splat = params['splat'] || params[:splat]
      id = splat.is_a?(Array) ? splat.first : splat
      halt 400, 'Missing LexicalEntry id' if id.nil? || id.empty?
      id = normalize_iri(id)
      
      # Get mappings for this lexical entry
      # Include LOOM and SAME_URI mappings as well as REST/CUI
      entry_uri = RDF::URI.new(id)
      sources = ["REST", "CUI", "LOOM", "SAME_URI"]
      mappings = LinkedData::Mappings.mappings_for_classids([entry_uri], sources)
      reply mappings || []
    end

    # Fetch a single lexical entry by IRI (encoded or with slashes)
    get '/*' do
      includes_param_check(LinkedData::Models::OntoLex::LexicalEntry)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      # Sinatra splat captures into params['splat'] (Array)
      id = if params['splat'].is_a?(Array)
             params['splat'].first
           else
             params['splat'] || params[:splat]
           end
      # Guard against bad matches (e.g., route conflicts like trailing /senses)
      if id.nil? || id.empty? || id.end_with?('/senses')
        halt 404, 'LexicalEntry id not provided or invalid'
      end
      # Allow encoded and double-encoded IRIs
      id = normalize_iri(id)
      ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:all])
      entry = LinkedData::Models::OntoLex::LexicalEntry.list_for_ids(submission, [id], ld).first
      error 404, "LexicalEntry not found: #{id}" if entry.nil?
      reply entry
    end

    # Simple search within lexical entries for this ontology (optional convenience)
    get '/search' do
      ont, submission = get_ontology_and_submission
      q = (params['q'] || '').strip

      if LinkedData::Models::OntoLex::LexicalEntry.respond_to?(:search)
        search_params = params.dup
        # constrain to current ontology
        search_params['ontologies'] = ont.acronym
        include Sinatra::Helpers::SearchHelper
        set_page_params(search_params)
        resp = LinkedData::Models::OntoLex::LexicalEntry.search(q.empty? ? '*:*' : q, search_params)
        total_found = resp["response"]["numFound"]

        docs = []
        resp["response"]["docs"].each do |doc|
          d = doc.symbolize_keys
          resource_id = d[:resource_id]
          d.delete :resource_id
          d[:id] = resource_id
          d[:submission] = submission
          instance = LinkedData::Models::OntoLex::LexicalEntry.read_only(d)
          docs << instance
        end
        page = page_object(docs, total_found)
        return reply 200, page
      end
      
    end

    private
    def normalize_iri(raw)
      val = raw.to_s
      val = val.sub(/^(https?):[\/]+/, '\1://')
      val
    end

    # Get a display label for a lexical entry (lemma or writtenRep from forms)
    def get_entry_label(entry, submission)
      # Try lemma first
      return entry.lemma.to_s if entry.respond_to?(:lemma) && entry.lemma && !entry.lemma.to_s.empty?
      
      # Try to get writtenRep from forms
      if entry.respond_to?(:form) && entry.form && !entry.form.empty?
        form_ids = Array(entry.form)
        begin
          forms_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:writtenRep])
          forms = LinkedData::Models::OntoLex::Form.list_for_ids(submission, form_ids, forms_ld)
          reps = forms.map { |f| f.writtenRep }.compact
          return reps.first.to_s unless reps.empty?
        rescue StandardError
          # Fallback to ID
        end
      end
      
      # Fallback to last part of ID
      entry.id.to_s.split('/').last
    end

    def includes_param_check(klass)
      if includes_param && !includes_param.empty?
        # validate allowed attributes for the klass
        allowed = klass.attributes + [:all]
        leftover = includes_param - allowed
        error(400, "Invalid include params: #{leftover.join(', ')}") unless leftover.empty?
      end
    end

  end
end
