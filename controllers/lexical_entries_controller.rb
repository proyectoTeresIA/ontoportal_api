require 'cgi'
class LexicalEntriesController < ApplicationController

  namespace "/ontologies/:ontology/lexical_entries" do

    # List lexical entries for an ontology submission
    get do
      includes_param_check(LinkedData::Models::OntoLex::LexicalEntry)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      page, size = page_params
      ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:all])
      items = LinkedData::Models::OntoLex::LexicalEntry.list_in_submission(submission, page, size, ld)
      total = LinkedData::Models::OntoLex::LexicalEntry.count_in_submission(submission)
      reply page_object(items, total)
    end

    # List senses for a given lexical entry (must be before wildcard show route).
    # Use a wildcard segment and splat capture so IRIs with slashes are captured fully.
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
      # decode up to twice
      2.times do
        begin
          decoded = CGI.unescape(val)
          val = decoded if decoded && decoded != val
        rescue StandardError
          break
        end
      end
      # fix scheme having one slash e.g., http:/example → http://example
      val = val.sub(/^(https?):\/(?!\/)/, '\1://')
      val
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
