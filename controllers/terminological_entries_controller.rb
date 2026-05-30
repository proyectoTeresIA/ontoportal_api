require 'cgi'
require 'zlib'

class TerminologicalEntriesController < ApplicationController
  # Redis client for caching the full sorted entry list per submission.
  TERM_CACHE_REDIS = Redis.new(
    host: LinkedData::OntologiesAPI.settings.http_redis_host,
    port: LinkedData::OntologiesAPI.settings.http_redis_port,
    connect_timeout: 2,
    timeout: 2
  )
  TERM_CACHE_TTL = 7_200

  # Serialize items to a Zlib-compressed JSON string for compact Redis storage.
  # Kept for the /languages endpoint cache only.
  def self.cache_serialize(items)
    Zlib::Deflate.deflate(items.to_json)
  end

  def self.cache_deserialize(raw)
    JSON.parse(Zlib::Inflate.inflate(raw)).map { |i| i.transform_keys(&:to_sym) }
  end

  # Return a sorted array of entry URIs for a graph, ordered alphabetically by
  # the first (lexicographically smallest) writtenRep of each entry's forms.
  # The array is cached in Redis so the expensive GROUP BY query runs only once
  # per submission. On cache miss the method blocks for ~6-8 s for large
  # ontologies (e.g. IATE with 88 k entries), but subsequent calls are fast
  # (Redis round-trip + decompression).
  def self.sort_index(graph)
    cache_key = "term_sort_v1:#{graph}"

    begin
      cached = TERM_CACHE_REDIS.get(cache_key)
      return JSON.parse(Zlib::Inflate.inflate(cached)) if cached
    rescue => e
      # Log and rebuild below rather than serving stale/broken data.
    end

    epr = Goo.sparql_query_client(:main)
    rows = epr.query(<<~SPARQL)
      SELECT ?entry (MIN(STR(?writtenRep)) AS ?sortKey)
      WHERE {
        GRAPH <#{graph}> {
          ?entry <#{ONTOLEX_NS}lexicalForm> ?form .
          ?form  <#{ONTOLEX_NS}writtenRep>  ?writtenRep .
        }
      }
      GROUP BY ?entry
      LIMIT 500000
    SPARQL

    pairs = []
    rows.each do |r|
      uri = r[:entry]&.to_s
      key = r[:sortKey]&.to_s.to_s
      pairs << [uri, key] if uri
    end
    pairs.sort_by! { |_, k| k.gsub(/<[^>]+>/, '').gsub(/\A[^\p{L}\p{N}]+/u, '').downcase }
    uris = pairs.map(&:first)

    begin
      TERM_CACHE_REDIS.setex(cache_key, TERM_CACHE_TTL, Zlib::Deflate.deflate(uris.to_json))
    rescue => e
      # Proceed without caching — just slower next time.
    end

    uris
  rescue => e
    nil  # Fall back to SPARQL-based ordering on any error.
  end

  ONTOLEX_NS = 'http://www.w3.org/ns/lemon/ontolex#'
  DCTERMS_NS = 'http://purl.org/dc/terms/'

  # Run a raw SPARQL SELECT against the main endpoint.
  def self.sparql_query(sparql)
    Goo.sparql_query_client(:main).query(sparql)
  end

  namespace "/ontologies/:ontology/terminological_entries" do

    # List terminological entries for an ontology, with optional text search,
    # language filter, and find_id navigation. All paths use 3 SPARQL queries
    # so the full dataset is never loaded into memory.
    #
    # Pagination is based on ORDER BY ASC(?entry) (URI lexicographic order).
    # This is intentionally different from alphabetical label order but is the
    # only approach that is fast for very large ontologies on 4store — joining
    # with writtenRep and ORDER BY on that literal requires a full sort of all
    # form rows before LIMIT can be applied (5.6 M rows for IATE, ~34s).
    #
    # Queries:
    #   1. COUNT(DISTINCT ?entry) with filter clauses → totalCount
    #   2. SELECT DISTINCT ?entry ?language with filter + ORDER BY + LIMIT/OFFSET
    #   3. SELECT forms for the page's entries via FILTER IN (fast: ≤ pagesize entries)
    get do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      page, size      = page_params
      search_query    = (params['q']        || '').strip.downcase
      language_filter = (params['language'] || '').strip
      find_id         = params['find_id']

      graph = submission.id.to_s
      epr   = Goo.sparql_query_client(:main)

      # ── Input validation ────────────────────────────────────────────────
      # language_filter may be a full URI or a bare ISO 639-3 code.
      # Reject values that contain characters that could be used for injection.
      unless language_filter.empty? || language_filter =~ /\A[\w:\/.#\-%]+\z/
        error 400, 'Invalid language parameter'
      end

      # ── Browse path: alphabetical sort via Redis sort-index ───────────────
      # When there is no text search and no language filter we use a pre-built
      # sorted URI list stored in Redis.  Building it (cache miss) takes ~6-8 s
      # for 88 k-entry ontologies but runs only once per submission.  All
      # subsequent requests are fast: Redis read + Ruby slice + FILTER IN.
      # If the sort index is unavailable (error / empty ontology) we fall back
      # to the URI-ordered SPARQL path below.
      if search_query.empty? && language_filter.empty?
        sorted_uris = TerminologicalEntriesController.sort_index(graph)
      end

      if sorted_uris && sorted_uris.any?
        total = sorted_uris.length

        # find_id: locate the page for a specific entry in the sorted list.
        if find_id && !find_id.empty?
          norm_fid = normalize_iri(find_id)
          pos  = sorted_uris.index(norm_fid) || 0
          page = (pos / size) + 1
        end

        offset    = (page - 1) * size
        page_uris = sorted_uris.slice(offset, size) || []

        entries_map = page_uris.each_with_object({}) do |uri, h|
          h[uri] = { form_ids: [], writtenReps: [], language: nil }
        end

        if page_uris.any?
          uri_list = page_uris.map { |u| "<#{u}>" }.join(', ')

          # Fetch language for this page's entries.
          epr.query(<<~SPARQL).each do |row|
            SELECT ?entry ?language
            WHERE {
              GRAPH <#{graph}> {
                ?entry <#{DCTERMS_NS}language> ?language .
                FILTER (?entry IN (#{uri_list}))
              }
            }
          SPARQL
            eid = row[:entry]&.to_s
            entries_map[eid][:language] = row[:language]&.to_s.presence if entries_map[eid]
          end

          # Fetch forms for this page's entries.
          epr.query(<<~SPARQL).each do |row|
            SELECT ?entry ?form ?writtenRep
            WHERE {
              GRAPH <#{graph}> {
                ?entry <#{ONTOLEX_NS}lexicalForm> ?form .
                ?form  <#{ONTOLEX_NS}writtenRep>  ?writtenRep .
                FILTER (?entry IN (#{uri_list}))
              }
            }
          SPARQL
            eid  = row[:entry]&.to_s
            next unless eid && entries_map[eid]
            fid_form = row[:form].to_s
            rep      = row[:writtenRep]&.to_s
            next if entries_map[eid][:form_ids].include?(fid_form)
            entries_map[eid][:form_ids] << fid_form
            entries_map[eid][:writtenReps] << rep if rep
          end
        end

        enriched_entries = page_uris.map do |eid|
          item = entries_map[eid]
          h = { '@id' => eid, 'id' => eid,
                'form' => item[:form_ids], 'writtenReps' => item[:writtenReps] }
          h['language'] = item[:language] if item[:language]
          h
        end

      else
        # ── Search / filter / fallback path ─────────────────────────────────
        # Handles text search (q=), language filter, and browse when sort_index
        # is unavailable.  ORDER BY on the filtered subset is fast because
        # search results are typically small.

        # ── SPARQL fragment: text search ────────────────────────────────────
        text_join = ''
        unless search_query.empty?
          re_safe = search_query
                      .gsub('\\', '\\\\').gsub('"',  '\\"')
                      .gsub('.',  '\\.') .gsub('*',  '\\*')
                      .gsub('+',  '\\+') .gsub('?',  '\\?')
                      .gsub('^',  '\\^') .gsub('$',  '\\$')
                      .gsub('(',  '\\(') .gsub(')',  '\\)')
                      .gsub('[',  '\\[') .gsub(']',  '\\]')
                      .gsub('{',  '\\{') .gsub('}',  '\\}')
          text_join = <<~FRAG
            ?entry <#{ONTOLEX_NS}lexicalForm> ?_srch_form .
            ?_srch_form <#{ONTOLEX_NS}writtenRep> ?_srch_rep .
            FILTER (REGEX(STR(?_srch_rep), "#{re_safe}", "i"))
          FRAG
        end

        # ── SPARQL fragment: language filter ────────────────────────────────
        lang_triple        = ''
        lang_filter_clause = ''
        unless language_filter.empty?
          lang_triple = "?entry <#{DCTERMS_NS}language> ?language ."
          if language_filter.start_with?('http')
            lang_filter_clause = "FILTER (STR(?language) = \"#{language_filter}\") ."
          else
            lang_filter_clause = "FILTER (REGEX(STR(?language), \"[/#]#{language_filter}$\")) ."
          end
        end

        # ── Query 1: total count ─────────────────────────────────────────────
        total = (epr.query(<<~SPARQL).first&.[](:c)&.object&.to_i) || 0
          SELECT (COUNT(DISTINCT ?entry) AS ?c)
          WHERE {
            GRAPH <#{graph}> {
              ?entry a <#{ONTOLEX_NS}LexicalEntry> .
              #{text_join}
              #{lang_triple}
              #{lang_filter_clause}
            }
          }
        SPARQL

        # ── find_id: locate the page containing a specific entry ─────────────
        if find_id && !find_id.empty?
          norm_fid = normalize_iri(find_id)
          position = (epr.query(<<~SPARQL).first&.[](:c)&.object&.to_i) || 0
            SELECT (COUNT(DISTINCT ?entry) AS ?c)
            WHERE {
              GRAPH <#{graph}> {
                ?entry a <#{ONTOLEX_NS}LexicalEntry> .
                #{text_join}
                #{lang_triple}
                #{lang_filter_clause}
                FILTER (STR(?entry) < "#{norm_fid}")
              }
            }
          SPARQL
          page = (position / size) + 1
        end

        # ── Query 2: page of entry URIs, ordered by entry URI ────────────────
        offset           = (page - 1) * size
        lang_or_optional = lang_triple.empty? \
          ? "OPTIONAL { ?entry <#{DCTERMS_NS}language> ?language . }" \
          : "#{lang_triple} #{lang_filter_clause}"

        entries_map = {}
        ordered_ids = []
        epr.query(<<~SPARQL).each do |row|
          SELECT DISTINCT ?entry ?language
          WHERE {
            GRAPH <#{graph}> {
              ?entry a <#{ONTOLEX_NS}LexicalEntry> .
              #{text_join}
              #{lang_or_optional}
            }
          }
          ORDER BY ASC(?entry)
          LIMIT #{size} OFFSET #{offset}
        SPARQL
          eid = row[:entry]&.to_s
          next unless eid
          unless entries_map[eid]
            entries_map[eid] = { form_ids: [], writtenReps: [],
                                 language: row[:language]&.to_s.presence }
            ordered_ids << eid
          end
        end

        # ── Query 3: forms for this page's entries ────────────────────────────
        if ordered_ids.any?
          uri_list = ordered_ids.map { |u| "<#{u}>" }.join(', ')
          epr.query(<<~SPARQL).each do |row|
            SELECT ?entry ?form ?writtenRep
            WHERE {
              GRAPH <#{graph}> {
                ?entry <#{ONTOLEX_NS}lexicalForm> ?form .
                ?form  <#{ONTOLEX_NS}writtenRep>  ?writtenRep .
                FILTER (?entry IN (#{uri_list}))
              }
            }
          SPARQL
            eid  = row[:entry]&.to_s
            next unless eid && entries_map[eid]
            fid_form = row[:form].to_s
            rep      = row[:writtenRep]&.to_s
            next if entries_map[eid][:form_ids].include?(fid_form)
            entries_map[eid][:form_ids] << fid_form
            entries_map[eid][:writtenReps] << rep if rep
          end
        end

        enriched_entries = ordered_ids.map do |eid|
          item = entries_map[eid]
          h = { '@id' => eid, 'id' => eid,
                'form' => item[:form_ids], 'writtenReps' => item[:writtenReps] }
          h['language'] = item[:language] if item[:language]
          h
        end

      end

      reply page_object(enriched_entries, total)
    end

    # List unique language codes used across all terminological entries.
    # Cached separately from the entry list since it is called on every tab load.
    get '/languages' do
      ont, submission = get_ontology_and_submission

      cache_key = "term_entries_langs_v1:#{submission.id}"
      codes = nil

      begin
        cached = TERM_CACHE_REDIS.get(cache_key)
        codes = JSON.parse(Zlib::Inflate.inflate(cached)) if cached
      rescue => e
        logger.warn "[terminological_entries/languages] Redis read failed: #{e.message}"
      end

      unless codes
        graph = submission.id.to_s
        rows  = TerminologicalEntriesController.sparql_query(<<~SPARQL)
          SELECT DISTINCT ?language
          WHERE {
            GRAPH <#{graph}> {
              ?entry a <#{ONTOLEX_NS}LexicalEntry> .
              ?entry <#{DCTERMS_NS}language> ?language .
            }
          }
        SPARQL
        codes = rows.map { |r| r[:language]&.to_s }
                    .compact
                    .map { |uri| uri.split('/').last&.split('#')&.last }
                    .compact
                    .reject(&:empty?)
                    .sort
        logger.debug "Unique language codes for ontology #{ont.acronym}: #{codes.inspect}"

        if codes.any?
          begin
            TERM_CACHE_REDIS.setex(cache_key, TERM_CACHE_TTL, Zlib::Deflate.deflate(codes.to_json))
          rescue => e
            logger.warn "[terminological_entries/languages] Redis write failed: #{e.message}"
          end
        end
      end

      reply codes
    end

    get '/*' do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      # Get entry ID from splat
      id = if params['splat'].is_a?(Array)
             params['splat'].first
           else
             params['splat'] || params[:splat]
           end
      
      halt 404, 'Entry id not provided' if id.nil? || id.empty?
      id = normalize_iri(id)
      
      # Load the lexical entry with all attributes
      ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:all])
      entry = LinkedData::Models::OntoLex::LexicalEntry.list_for_ids(submission, [id], ld).first
      error 404, "Entry not found: #{id}" if entry.nil?
      
      # Use to_json and parse back to get a clean hash without empty objects
      entry_json = entry.to_json
      entry_hash = JSON.parse(entry_json)
      
      # Load and enrich forms with all their data
      if entry.form && !entry.form.empty?
        form_ids = Array(entry.form)
        forms_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:all])
        forms = LinkedData::Models::OntoLex::Form.list_for_ids(submission, form_ids, forms_ld)
        entry_hash['loadedForms'] = forms.map { |f| JSON.parse(f.to_json) }
      end
      
      # Load and enrich senses
      if entry.sense && !entry.sense.empty?
        sense_ids = Array(entry.sense)
        senses_ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load([:all])
        senses = LinkedData::Models::OntoLex::LexicalSense.list_for_ids(submission, sense_ids, senses_ld)
        
        # Enrich senses with related lexical entries for translations/synonyms
        entry_hash['loadedSenses'] = senses.map do |sense|
          sense_hash = JSON.parse(sense.to_json)
          
          # Load related entries (translations, synonyms, etc.) with their writtenReps
          [:translation, :synonym, :antonym].each do |rel_type|
            if sense.respond_to?(rel_type) && sense.send(rel_type)
              rel_sense_ids = Array(sense.send(rel_type))
              next if rel_sense_ids.empty?
              
              # Load related senses
              rel_senses_ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load([:isSenseOf])
              rel_senses = LinkedData::Models::OntoLex::LexicalSense.list_for_ids(submission, rel_sense_ids, rel_senses_ld)
              
              # For each related sense, load its entry and forms to get writtenReps and language
              sense_hash["loaded_#{rel_type}"] = rel_senses.map do |rel_sense|
                rel_sense_hash = JSON.parse(rel_sense.to_json)
                
                if rel_sense.isSenseOf
                  entry_id = rel_sense.isSenseOf
                  rel_entry_ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load([:form, :language])
                  rel_entry = LinkedData::Models::OntoLex::LexicalEntry.list_for_ids(submission, [entry_id], rel_entry_ld).first
                  
                  if rel_entry && rel_entry.form
                    form_ids = Array(rel_entry.form)
                    forms_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:writtenRep])
                    forms = LinkedData::Models::OntoLex::Form.list_for_ids(submission, form_ids, forms_ld)
                    rel_sense_hash['writtenReps'] = forms.map { |f| f.writtenRep }.compact
                  end
                  rel_sense_hash['language'] = rel_entry.language.to_s if rel_entry.language
                  rel_sense_hash['entryId'] = entry_id.to_s
                end
                
                rel_sense_hash
              end
            end
          end
          
          sense_hash
        end
      end
      
      # Load evoked concept if present
      if entry.evokes
        concept_id = entry.evokes
        concept_ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load([:all])
        concept = LinkedData::Models::OntoLex::LexicalConcept.list_for_ids(submission, [concept_id], concept_ld).first
        if concept
          concept_hash = JSON.parse(concept.to_json)
          concept_hash['inScheme'] = expand_in_scheme_values(concept_hash['inScheme'], submission)
          entry_hash['loadedConcept'] = concept_hash

          source_summary = extract_source_summary_from_concept(concept_hash)
          entry_hash['sourceResource'] = source_summary if source_summary
        end

        # Load cross-ontology SKOS terms for this concept
        cross_terms = LinkedData::Mappings.ontolex_skos_cross_entries(submission, concept_id.to_s)
        entry_hash['crossOntologyTerms'] = cross_terms unless cross_terms.empty?
      end
      
      reply entry_hash
    end

    private
    
    # Enrich a lexical entry with form writtenReps
    def enrich_entry(entry, submission)
      entry_hash = {
        '@id' => entry.id.to_s,
        'id' => entry.id.to_s
      }
      
      # Add language if loaded
      entry_hash['language'] = entry.language.to_s if entry.language
      
      # Add form URIs if loaded
      if entry.form && !entry.form.empty?
        form_ids = Array(entry.form)
        entry_hash['form'] = form_ids.map(&:to_s)
        
        # Load forms and extract writtenReps
        forms_ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load([:writtenRep])
        forms = LinkedData::Models::OntoLex::Form.list_for_ids(submission, form_ids, forms_ld)
        entry_hash['writtenReps'] = forms.map { |f| f.writtenRep }.compact
      else
        entry_hash['form'] = []
        entry_hash['writtenReps'] = []
      end
      
      entry_hash
    end
    
    def normalize_iri(raw)
      val = raw.to_s
      val = val.sub(/^(https?):[\/]+/, '\1://')
      val
    end

    def expand_in_scheme_values(in_scheme_values, submission)
      normalize_to_array(in_scheme_values).map do |scheme|
        scheme_uri = extract_uri_value(scheme)
        next scheme unless scheme_uri && !scheme_uri.empty?

        LinkedData::Models::OntoLex::LexicalConcept.expand_in_scheme_for_concept(scheme_uri, submission)
      rescue StandardError
        scheme
      end.compact
    end

    def extract_uri_value(value)
      return nil if value.nil?
      return value.to_s if value.is_a?(String)
      return value.id.to_s if value.respond_to?(:id) && value.id

      if value.is_a?(Array)
        return value[1].to_s if value.length == 2 && value[0].to_s == 'uri'
        return extract_uri_value(value.first)
      end

      if value.is_a?(Hash)
        return value['@id'] if value['@id']
        return value['id'] if value['id']
        return value['uri'] if value['uri']
      end

      value.respond_to?(:to_s) ? value.to_s : nil
    end

    def normalize_to_array(value)
      return [] if value.nil?
      return value if value.is_a?(Array)

      [value]
    end

    def extract_source_summary_from_concept(concept_hash)
      return nil unless concept_hash.is_a?(Hash)

      in_schemes = Array(concept_hash['inScheme'])
      source_obj = in_schemes.map do |scheme|
        scheme.is_a?(Hash) ? scheme['source'] : nil
      end.compact.first

      return nil unless source_obj

      if source_obj.is_a?(Hash)
        summary = {
          '@id' => source_obj['@id'] || source_obj['id']
        }
        summary['resourceName'] = source_obj['resourceName'] if source_obj['resourceName']
        summary['url'] = source_obj['url'] if source_obj['url']
        summary['uri'] = source_obj['uri'] if source_obj['uri']
        summary['resourceCreator'] = source_obj['resourceCreator'] if source_obj['resourceCreator']
        summary['language'] = source_obj['language'] if source_obj['language']
        summary['domain'] = source_obj['domain'] if source_obj['domain']
        return summary
      end

      { '@id' => source_obj.to_s }
    end
  end
end
