require_relative '../test_case'
require 'cgi'
require 'tmpdir'

class TestOntoLexControllers < TestCase

  def before_suite
    LinkedData.config do |config|
      config.goo_backend_name = ENV.fetch('GOO_BACKEND_NAME', 'ag')
      config.goo_host         = ENV.fetch('GOO_HOST', 'localhost')
      config.goo_port         = Integer(ENV.fetch('GOO_PORT', '10035'))
      config.goo_path_query   = ENV.fetch('GOO_PATH_QUERY', '/repositories/ontoportal_test')
      config.goo_path_data    = ENV.fetch('GOO_PATH_DATA', '/repositories/ontoportal_test/statements')
      config.goo_path_update  = ENV.fetch('GOO_PATH_UPDATE', '/repositories/ontoportal_test/statements')

      # Caches/security off for a diagnostic script
      Goo.use_cache            = false
      config.enable_http_cache = false
      config.enable_security   = false

      # Optional but harmless in CLI context
      config.rest_url_prefix = ENV['REST_URL_PREFIX'] if ENV['REST_URL_PREFIX']
      config.id_url_prefix   = ENV['ID_URL_PREFIX']   if ENV['ID_URL_PREFIX']
    end
    # Create a tiny OntoLex submission using the helper script or inline via the OntoLex parser
    # We'll manufacture a minimal graph and parse it into a test submission to keep tests hermetic.
    @acronym = 'ONTOLEXTEST'
    @entry   = 'http://example.org/lex/entry1'
    @form    = 'http://example.org/lex/form1'
    @sense   = 'http://example.org/lex/sense1'
    @concept = 'http://example.org/lex/concept1'

    # Create ontology and submission
    # Always create a fresh ontology to avoid persistence/state issues
    existing = LinkedData::Models::Ontology.find(@acronym).to_a
    existing.each { |o| o.delete rescue nil }

    # Create a basic user to satisfy ontology validations (administeredBy requires a user)
    user = LinkedData::Models::User.find('test_user').first
    unless user
      user = LinkedData::Models::User.new(username: 'test_user', email: 't@example.org', password: 'changeme')
      unless user.save
        raise "Failed to save user: #{user.errors}"
      end
    end

    ont = LinkedData::Models::Ontology.new
    ont.acronym = @acronym
    ont.name = 'OntoLex Test'
    ont.viewingRestriction = :public
    ont.administeredBy = [user]
    # Allow submissions without requiring a full uploaded file
    ont.summaryOnly = true
    unless ont.save
      raise "Failed to save ontology: #{ont.errors}
             acronym=#{@acronym} name=#{ont.name}"
    end

    # Build tiny N-Triples we will use for parsing and for uploadFilePath
    nt = <<~NT
      <#{@entry}>  <http://www.w3.org/1999/02/22-rdf-syntax-ns#type>  <http://www.w3.org/ns/lemon/ontolex#LexicalEntry> .
      <#{@entry}>  <http://www.w3.org/ns/lemon/ontolex#canonicalForm> <#{@form}> .
      <#{@form}>   <http://www.w3.org/1999/02/22-rdf-syntax-ns#type>  <http://www.w3.org/ns/lemon/ontolex#Form> .
      <#{@form}>   <http://www.w3.org/ns/lemon/ontolex#writtenRep>    "test"@en .
      <#{@entry}>  <http://www.w3.org/ns/lemon/ontolex#sense>         <#{@sense}> .
      <#{@sense}>  <http://www.w3.org/1999/02/22-rdf-syntax-ns#type>  <http://www.w3.org/ns/lemon/ontolex#LexicalSense> .
      <#{@sense}>  <http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf> <#{@concept}> .
      <#{@concept}> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/2004/02/skos/core#Concept> .
      <#{@concept}> <http://www.w3.org/2004/02/skos/core#prefLabel>   "Test concept"@en .
    NT
    path = File.join(Dir.tmpdir, "ontolex_test_#{$$}.nt")
    File.write(path, nt)

    sub = LinkedData::Models::OntologySubmission.new
    sub.ontology = ont
    # Avoid calling next_submission_id on a newly created ontology in tests
    sub.submissionId = 1
    # Provide a file path to satisfy validations
    sub.uploadFilePath = path
    sub.masterFileName = File.basename(path)
    sub.contact = [LinkedData::Models::Contact.new(name: 'T', email: 't@example.org').save]
    sub.released = DateTime.now
    fmt = LinkedData::Models::OntologyFormat.find('OWL').first
    sub.hasOntologyLanguage = fmt if fmt
    status_uploaded = LinkedData::Models::SubmissionStatus.find('UPLOADED').first
    status_rdf      = LinkedData::Models::SubmissionStatus.find('RDF').first
    sub.add_submission_status(status_uploaded) if status_uploaded
    sub.add_submission_status(status_rdf) if status_rdf
    sub.save

    LinkedData::Parser::OntoLex.parse(path, sub)

    # Ensure triples exist in the submission graph for Goo queries
    begin
      g = sub.id.to_s
      inserts = <<~SPARQL
        INSERT { GRAPH <#{g}> { <#{@entry}> a <http://www.w3.org/ns/lemon/ontolex#LexicalEntry> } } WHERE { BIND(1 as ?x) }
        ; INSERT { GRAPH <#{g}> { <#{@entry}> <http://www.w3.org/ns/lemon/ontolex#canonicalForm> <#{@form}> } } WHERE { BIND(1 as ?x) }
        ; INSERT { GRAPH <#{g}> { <#{@form}> a <http://www.w3.org/ns/lemon/ontolex#Form> } } WHERE { BIND(1 as ?x) }
        ; INSERT { GRAPH <#{g}> { <#{@form}> <http://www.w3.org/ns/lemon/ontolex#writtenRep> "test"@en } } WHERE { BIND(1 as ?x) }
        ; INSERT { GRAPH <#{g}> { <#{@entry}> <http://www.w3.org/ns/lemon/ontolex#sense> <#{@sense}> } } WHERE { BIND(1 as ?x) }
        ; INSERT { GRAPH <#{g}> { <#{@sense}> a <http://www.w3.org/ns/lemon/ontolex#LexicalSense> } } WHERE { BIND(1 as ?x) }
        ; INSERT { GRAPH <#{g}> { <#{@sense}> <http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf> <#{@concept}> } } WHERE { BIND(1 as ?x) }
        ; INSERT { GRAPH <#{g}> { <#{@concept}> a <http://www.w3.org/2004/02/skos/core#Concept> } } WHERE { BIND(1 as ?x) }
      SPARQL
      Goo.sparql_update_client.update(inserts)
    rescue StandardError
      # non-fatal in case graph already has data
    end
  end

  def after_suite
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
  end

  def test_entries_list_and_show
    ont = Ontology.find(@acronym).include(:acronym).first
    get "/ontologies/#{ont.acronym}/lexical_entries"
    assert last_response.ok?, get_errors(last_response)
    page = MultiJson.load(last_response.body)
    assert page["page"] == 1
    assert page["pageCount"] >= 1
    assert page["totalCount"] >= 1
    assert_instance_of Array, page["collection"]
    assert page["collection"].any?

    enc_id = CGI.escape(@entry)
    get "/ontologies/#{ont.acronym}/lexical_entries/#{enc_id}"
    assert last_response.ok?, get_errors(last_response)
    show = MultiJson.load(last_response.body)
    assert_equal @entry, show["@id"]
    # Ensure embedded form and sense are present (parity with list/show relies on model getters)
    assert show["form"].is_a?(Array)
    assert show["sense"].is_a?(Array)
  end

  def test_forms_list_and_show
    ont = Ontology.find(@acronym).include(:acronym).first
    get "/ontologies/#{ont.acronym}/forms"
    assert last_response.ok?, get_errors(last_response)
    page = MultiJson.load(last_response.body)
    assert page["totalCount"] >= 1
    first = page["collection"].first
    assert first["writtenRep"], 'writtenRep must be present'

    enc_form = CGI.escape(@form)
    get "/ontologies/#{ont.acronym}/forms/#{enc_form}"
    assert last_response.ok?, get_errors(last_response)
    show = MultiJson.load(last_response.body)
    assert_equal @form, show["@id"]
    assert show["writtenRep"]
  end

  def test_senses_list_and_show
    ont = Ontology.find(@acronym).include(:acronym).first
    get "/ontologies/#{ont.acronym}/lexical_senses"
    assert last_response.ok?, get_errors(last_response)
    page = MultiJson.load(last_response.body)
    assert page["totalCount"] >= 1
    first = page["collection"].first
    # lexicalConcept linkage may appear as array
    assert first["lexicalConcept"], 'lexicalConcept should be present via inverse path'

    enc_sense = CGI.escape(@sense)
    get "/ontologies/#{ont.acronym}/lexical_senses/#{enc_sense}"
    assert last_response.ok?, get_errors(last_response)
    show = MultiJson.load(last_response.body)
    assert_equal @sense, show["@id"]
    assert show["lexicalConcept"], 'lexicalConcept should be present on show'
  end

  def test_concepts_list_and_show
    ont = Ontology.find(@acronym).include(:acronym).first
    get "/ontologies/#{ont.acronym}/lexical_concepts"
    assert last_response.ok?, get_errors(last_response)
    page = MultiJson.load(last_response.body)
    assert page["totalCount"] >= 1
    assert page["collection"].any?

    enc_concept = CGI.escape(@concept)
    get "/ontologies/#{ont.acronym}/lexical_concepts/#{enc_concept}"
    assert last_response.ok?, get_errors(last_response)
    show = MultiJson.load(last_response.body)
    assert_equal @concept, show["@id"]
    # Accept either string or map for prefLabel per serializer config
    assert show["prefLabel"], 'prefLabel should be present on concept'
  end

  def test_wildcard_show_with_slashes
    ont = Ontology.find(@acronym).include(:acronym).first
    # Ensure %2F encoded still resolves
    enc_entry = CGI.escape(@entry)
    get "/ontologies/#{ont.acronym}/lexical_entries/#{enc_entry}"
    assert last_response.ok?, get_errors(last_response)
    enc_form = CGI.escape(@form)
    get "/ontologies/#{ont.acronym}/forms/#{enc_form}"
    assert last_response.ok?, get_errors(last_response)
    enc_sense = CGI.escape(@sense)
    get "/ontologies/#{ont.acronym}/lexical_senses/#{enc_sense}"
    assert last_response.ok?, get_errors(last_response)
    enc_concept = CGI.escape(@concept)
    get "/ontologies/#{ont.acronym}/lexical_concepts/#{enc_concept}"
    assert last_response.ok?, get_errors(last_response)
  end

end
