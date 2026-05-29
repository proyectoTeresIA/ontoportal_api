require 'cgi'
require 'zlib'

class TerminologicalEntriesController < ApplicationController
  helpers OntolexSearchHelper

  # Redis client for caching the full sorted entry list per submission.
  TERM_CACHE_REDIS = Redis.new(
    host: LinkedData::OntologiesAPI.settings.http_redis_host,
    port: LinkedData::OntologiesAPI.settings.http_redis_port,
    connect_timeout: 2,
    timeout: 2
  )
  TERM_CACHE_TTL = 7_200

  # Serialize items to a Zlib-compressed JSON string for compact Redis storage.
  def self.cache_serialize(items)
    Zlib::Deflate.deflate(items.to_json)
  end

  def self.cache_deserialize(raw)
    JSON.parse(Zlib::Inflate.inflate(raw)).map { |i| i.transform_keys(&:to_sym) }
  end

  ONTOLEX_NS = 'http://www.w3.org/ns/lemon/ontolex#'
  DCTERMS_NS = 'http://purl.org/dc/terms/'

  # Run a raw SPARQL SELECT against the main endpoint.
  def self.sparql_query(sparql)
    Goo.sparql_query_client(:main).query(sparql)
  end

  # Fetch all entries+forms from the triple-store in a single SPARQL query and
  # return them as an array of hashes ready for Redis caching.
  def self.load_all_items(graph)
    rows = sparql_query(<<~SPARQL)
      SELECT ?entry ?form ?writtenRep ?language
      WHERE {
        GRAPH <#{graph}> {
          ?entry a <#{ONTOLEX_NS}LexicalEntry> .
          OPTIONAL {
            ?entry <#{ONTOLEX_NS}lexicalForm> ?form .
            ?form  <#{ONTOLEX_NS}writtenRep>  ?writtenRep .
          }
          OPTIONAL { ?entry <#{DCTERMS_NS}language> ?language . }
        }
      }
    SPARQL

    entries_map = {}
    rows.each do |row|
      eid = row[:entry]&.to_s
      next unless eid
      entries_map[eid] ||= {
        id: eid, form_ids: [], writtenReps: [], label_lower: '',
        language: row[:language]&.to_s.presence
      }
      next unless row[:form]
      fid = row[:form].to_s
      rep = row[:writtenRep]&.to_s
      next if entries_map[eid][:form_ids].include?(fid)
      entries_map[eid][:form_ids] << fid
      entries_map[eid][:writtenReps] << rep if rep
    end

    entries_map.each_value do |item|
      label = item[:writtenReps].first || item[:id].split('/').last
      item[:label_lower] = label.to_s.downcase
    end
    entries_map.values
  end

  namespace "/ontologies/:ontology/terminological_entries" do

    get do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      page, size = page_params
      search_query   = (params['q']        || '').strip.downcase
      language_filter = (params['language'] || '').strip
      find_id        = params['find_id']

      graph = submission.id.to_s

      # ── Fast path: pure browse with no filter / search / find_id ────────────
      # Fetches only the requested page directly from the triple-store using
      # SPARQL ORDER BY + LIMIT/OFFSET. The full entry list is never loaded into
      # memory and Redis is not involved, so the first request for a large
      # ontology (e.g. IATE with 87 k entries) returns in seconds rather than
      # minutes.
      if search_query.empty? && language_filter.empty? && find_id.nil?
        epr = Goo.sparql_query_client(:main)

        total = (epr.query(
          "SELECT (COUNT(DISTINCT ?e) AS ?c) WHERE { GRAPH <#{graph}> { ?e a <#{ONTOLEX_NS}LexicalEntry> } }"
        ).first&.[](:c)&.object&.to_i) || 0

        offset = (page - 1) * size
        # Fetch up to 4× as many rows as needed so that entries with multiple
        # forms (each producing its own ORDER-BY row) still yield a full page.
        rows = epr.query(<<~SPARQL)
          SELECT ?entry ?form ?writtenRep ?language
          WHERE {
            GRAPH <#{graph}> {
              ?entry a <#{ONTOLEX_NS}LexicalEntry> .
              OPTIONAL {
                ?entry <#{ONTOLEX_NS}lexicalForm> ?form .
                ?form  <#{ONTOLEX_NS}writtenRep>  ?writtenRep .
              }
              OPTIONAL { ?entry <#{DCTERMS_NS}language> ?language . }
            }
          }
          ORDER BY ASC(?writtenRep) ASC(?entry)
          LIMIT #{size * 4} OFFSET #{offset}
        SPARQL

        # Collapse multiple rows for the same entry (multi-form case).
        entries_map = {}
        ordered_ids = []
        rows.each do |row|
          eid = row[:entry]&.to_s
          next unless eid
          if entries_map[eid].nil?
            next if ordered_ids.size >= size   # already have enough distinct entries
            entries_map[eid] = { form_ids: [], writtenReps: [],
                                 language: row[:language]&.to_s.presence }
            ordered_ids << eid
          end
          next unless row[:form]
          fid = row[:form].to_s
          rep = row[:writtenRep]&.to_s
          next if entries_map[eid][:form_ids].include?(fid)
          entries_map[eid][:form_ids] << fid
          entries_map[eid][:writtenReps] << rep if rep
        end

        enriched_entries = ordered_ids.map do |eid|
          item = entries_map[eid]
          h = { '@id' => eid, 'id' => eid,
                'form' => item[:form_ids], 'writtenReps' => item[:writtenReps] }
          h['language'] = item[:language] if item[:language]
          h
        end

        reply page_object(enriched_entries, total)
        return
      end

      # ── Slow path: search / filter / find_id needs all entries in memory ────
      # Backed by Redis so the first request for each submission is the only
      # slow one.  Cache miss now uses a single raw SPARQL query rather than
      # two goo .all batched calls, which is significantly faster for large
      # ontologies.
      cache_key = "term_entries_v1:#{submission.id}"
      all_items = nil

      begin
        cached = TERM_CACHE_REDIS.get(cache_key)
        all_items = TerminologicalEntriesController.cache_deserialize(cached) if cached
      rescue => e
        logger.warn "[terminological_entries] Redis read failed: #{e.message}"
      end

      unless all_items
        all_items = TerminologicalEntriesController.load_all_items(graph)

        if all_items.any?
          begin
            TERM_CACHE_REDIS.setex(cache_key, TERM_CACHE_TTL,
                                   TerminologicalEntriesController.cache_serialize(all_items))
          rescue => e
            logger.warn "[terminological_entries] Redis write failed: #{e.message}"
          end
        end
      end

      # --- In-memory filter/sort/paginate (fast, operates on cached list) ---

      items = filter_and_sort_by_relevance(all_items, search_query)

      unless language_filter.empty?
        items = items.select do |item|
          lang = item[:language].to_s
          lang == language_filter ||
            lang.split('/').last == language_filter ||
            lang.split('#').last == language_filter
        end
      end

      total = items.length

      if find_id && !find_id.empty?
        find_id = normalize_iri(find_id)
        item_index = items.find_index { |item| item[:id].to_s == find_id }
        if item_index
          page = (item_index / size) + 1
          params['page'] = page.to_s
        end
      end

      start_idx = (page - 1) * size
      page_items = items.slice(start_idx, size) || []

      enriched_entries = page_items.map do |item|
        entry_hash = {
          '@id' => item[:id].to_s,
          'id' => item[:id].to_s,
          'form' => item[:form_ids],
          'writtenReps' => item[:writtenReps]
        }
        entry_hash['language'] = item[:language] if item[:language]
        entry_hash
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
                    .map { |uri| uri.split('/').last.split('#').last }
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
