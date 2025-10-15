class OntoLexEntriesController < ApplicationController

  namespace "/ontologies/:ontology/lexical_entries" do

    # List lexical entries for an ontology submission (paged)
    get do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      page, size = page_params
      ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load(includes_param)
      unmapped = ld.delete(:properties)

      entries = LinkedData::Models::OntoLex::LexicalEntry
                  .in(submission)
                  .include(ld)
                  .page(page, size)
                  .all

      # Fallback: if no entries are found within the submission graph, attempt a
      # direct SPARQL scan for ontolex:LexicalEntry subjects only within the
      # submission named graph.
      total_found = nil
      fallback_json = nil
      if entries.empty?
        begin
          ontolex_entry = "http://www.w3.org/ns/lemon/ontolex#LexicalEntry"
          rdf_type_http = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
          rdf_type_https = "https://www.w3.org/1999/02/22-rdf-syntax-ns#type"
          iris = []
          if submission && submission.id
            q = <<~SPARQL
              SELECT DISTINCT ?e WHERE {
                GRAPH <#{submission.id}> {
                  { ?e ?t <#{ontolex_entry}> FILTER (?t IN (<#{rdf_type_http}>, <#{rdf_type_https}>)) }
                  UNION
                  { ?e <http://www.w3.org/ns/lemon/ontolex#canonicalForm> ?f }
                }
              }
            SPARQL
            rs = Goo.sparql_query_client.query(q)
            iris = rs.map { |sol| sol[:e].to_s }
          end
          unless iris.empty?
            total_found = iris.length
            offset, limit = offset_and_limit(page, size)
            page_iris = iris[offset, limit] || []
            collection = page_iris.map do |id|
              { '@id' => id, 'links' => { 'self' => "/ontologies/#{ont.acronym}/lexical_entries/#{CGI.escape(id)}" } }
            end
            fallback_json = { 'page' => page, 'pageSize' => size, 'totalCount' => total_found, 'collection' => collection }
          end
        rescue StandardError
          # If SPARQL fallback fails, keep entries as empty
        end
      end

      if unmapped && entries.length > 0
        LinkedData::Models::OntoLex::LexicalEntry.in(submission).models(entries).include(:unmapped).all
      end

      # Return a Page object when models are available; otherwise explicit JSON hash
      if entries && !entries.empty?
        total_found ||= entries.length
        reply page_object(entries, total_found)
      else
        fallback_json ||= { 'page' => page, 'pageSize' => size, 'totalCount' => 0, 'collection' => [] }
        reply fallback_json
      end
    end

    # Get a single lexical entry
    get '/:entry' do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalEntry, [ont.acronym])

      ld = LinkedData::Models::OntoLex::LexicalEntry.goo_attrs_to_load(includes_param)
      unmapped = ld.delete(:properties) || (includes_param && includes_param.include?(:all))

      entry_id = RDF::URI.new(params[:entry])
      error 400, "The input entry id '#{params[:entry]}' is not a valid IRI" unless entry_id.valid?

      entry = LinkedData::Models::OntoLex::LexicalEntry
                .find(entry_id)
                .in(submission)
                .include(ld)
                .first
      # Fallback to explicit JSON if not found within submission
      if entry.nil?
        hash = { '@id' => entry_id.to_s, 'links' => { 'self' => "/ontologies/#{ont.acronym}/lexical_entries/#{CGI.escape(entry_id.to_s)}" } }
        reply hash
      else
        if unmapped
          LinkedData::Models::OntoLex::LexicalEntry.in(submission).models([entry]).include(:unmapped).all
        end
        reply entry
      end
    end

    # Forms for an entry
    get '/:entry/forms' do
      ont, submission = get_ontology_and_submission

      entry_id = RDF::URI.new(params[:entry])
      error 400, "The input entry id '#{params[:entry]}' is not a valid IRI" unless entry_id.valid?

      ld = LinkedData::Models::OntoLex::Form.goo_attrs_to_load(includes_param)
      unmapped = ld.delete(:properties)

      entry = LinkedData::Models::OntoLex::LexicalEntry.find(entry_id).in(submission).first
      if entry.nil?
        # SPARQL fallback scoped to submission graph
        e = entry_id.to_s
        g = submission&.id
        q = <<~SPARQL
          PREFIX ontolex: <http://www.w3.org/ns/lemon/ontolex#>
          SELECT ?f (SAMPLE(STR(?wr)) AS ?w) WHERE {
            GRAPH <#{g}> {
              VALUES ?e { <#{e}> }
              { ?e ontolex:canonicalForm ?f } UNION { ?e ontolex:otherForm ?f }
              OPTIONAL { ?f ontolex:writtenRep ?wr }
            }
          } GROUP BY ?f
        SPARQL
        rs = Goo.sparql_query_client.query(q)
        coll = rs.map do |sol|
          { '@id' => sol[:f].to_s, 'writtenRep' => (sol[:w].to_s.empty? ? nil : sol[:w].to_s) }
        end
        reply({ 'page' => 1, 'pageSize' => coll.length, 'totalCount' => coll.length, 'collection' => coll })
      else
        LinkedData::Models::OntoLex::LexicalEntry.in(submission).models([entry]).include(:form).all
        forms = entry.form || []
        if unmapped && forms.length > 0
          LinkedData::Models::OntoLex::Form.in(submission).models(forms).include(:unmapped).all
        end
        reply page_object(forms, forms.length)
      end
    end

    # Senses for an entry
    get '/:entry/senses' do
      ont, submission = get_ontology_and_submission

      entry_id = RDF::URI.new(params[:entry])
      error 400, "The input entry id '#{params[:entry]}' is not a valid IRI" unless entry_id.valid?

      ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load(includes_param)
      unmapped = ld.delete(:properties)

      entry = LinkedData::Models::OntoLex::LexicalEntry.find(entry_id).in(submission).first
      if entry.nil?
        # SPARQL fallback scoped to submission graph
        e = entry_id.to_s
        g = submission&.id
        q = <<~SPARQL
          PREFIX ontolex: <http://www.w3.org/ns/lemon/ontolex#>
          SELECT DISTINCT ?s WHERE {
            GRAPH <#{g}> { <#{e}> ontolex:sense ?s }
          }
        SPARQL
        rs = Goo.sparql_query_client.query(q)
        coll = rs.map { |sol| { '@id' => sol[:s].to_s } }
        reply({ 'page' => 1, 'pageSize' => coll.length, 'totalCount' => coll.length, 'collection' => coll })
      else
        LinkedData::Models::OntoLex::LexicalEntry.in(submission).models([entry]).include(:sense).all
        senses = entry.sense || []
        if unmapped && senses.length > 0
          LinkedData::Models::OntoLex::LexicalSense.in(submission).models(senses).include(:unmapped).all
        end
        reply page_object(senses, senses.length)
      end
    end

    # Concepts evoked by an entry
    get '/:entry/concepts' do
      ont, submission = get_ontology_and_submission

      entry_id = RDF::URI.new(params[:entry])
      error 400, "The input entry id '#{params[:entry]}' is not a valid IRI" unless entry_id.valid?

      ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load(includes_param)

      entry = LinkedData::Models::OntoLex::LexicalEntry.find(entry_id).in(submission).first
      if entry.nil?
        # SPARQL fallback scoped to submission graph
        e = entry_id.to_s
        g = submission&.id
        q = <<~SPARQL
          PREFIX ontolex: <http://www.w3.org/ns/lemon/ontolex#>
          PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
          SELECT ?c (SAMPLE(STR(?lbl)) AS ?l) WHERE {
            GRAPH <#{g}> {
              <#{e}> ontolex:sense ?s .
              ?s ontolex:isLexicalizedSenseOf ?c .
              OPTIONAL { ?c skos:prefLabel ?lbl }
            }
          } GROUP BY ?c
        SPARQL
        rs = Goo.sparql_query_client.query(q)
        coll = rs.map do |sol|
          lbl = sol[:l].to_s
          { '@id' => sol[:c].to_s, 'prefLabel' => (lbl.empty? ? nil : lbl) }
        end
        reply({ 'page' => 1, 'pageSize' => coll.length, 'totalCount' => coll.length, 'collection' => coll })
      else
        LinkedData::Models::OntoLex::LexicalEntry.in(submission).models([entry]).include(:concept).all
        concepts = entry.concept || []
        unless concepts.empty?
          LinkedData::Models::OntoLex::LexicalConcept.in(submission).models(concepts).include(ld).all
        end
        reply page_object(concepts, concepts.length)
      end
    end
  end
end
