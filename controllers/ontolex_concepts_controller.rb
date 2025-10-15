class OntoLexConceptsController < ApplicationController

  namespace "/ontologies/:ontology/lexical_concepts" do

    # List lexical concepts for an ontology submission (paged)
    get do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalConcept, [ont.acronym])

      page, size = page_params
      ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load(includes_param)
      unmapped = ld.delete(:properties)

      concepts = LinkedData::Models::OntoLex::LexicalConcept
                  .in(submission)
                  .include(ld)
                  .page(page, size)
                  .all

      if unmapped && concepts.length > 0
        LinkedData::Models::OntoLex::LexicalConcept.in(submission).models(concepts).include(:unmapped).all
      end

      reply concepts
    end

    # Get a single lexical concept
    get '/:concept' do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalConcept, [ont.acronym])

      ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load(includes_param)
      unmapped = ld.delete(:properties) || (includes_param && includes_param.include?(:all))

      concept_id = RDF::URI.new(params[:concept])
      error 400, "The input concept id '#{params[:concept]}' is not a valid IRI" unless concept_id.valid?

      concept = LinkedData::Models::OntoLex::LexicalConcept
                  .find(concept_id)
                  .in(submission)
                  .include(ld)
                  .first

      error 404, "LexicalConcept '#{params[:concept]}' not found in ontology #{ont.acronym}" if concept.nil?

      if unmapped
        LinkedData::Models::OntoLex::LexicalConcept.in(submission).models([concept]).include(:unmapped).all
      end

      reply concept
    end

    # Retrieve broader concepts
    get '/:concept/broader' do
      ont, submission = get_ontology_and_submission
      concept_id = RDF::URI.new(params[:concept])
      error 400, "The input concept id '#{params[:concept]}' is not a valid IRI" unless concept_id.valid?

      ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load(includes_param)
      concept = LinkedData::Models::OntoLex::LexicalConcept.find(concept_id).in(submission).first
      error 404, "LexicalConcept '#{params[:concept]}' not found in ontology #{ont.acronym}" if concept.nil?

      LinkedData::Models::OntoLex::LexicalConcept.in(submission).models([concept]).include(:broader).all
      broader = concept.broader || []
      unless broader.empty?
        LinkedData::Models::OntoLex::LexicalConcept.in(submission).models(broader).include(ld).all
      end
      reply broader
    end

    # Retrieve narrower concepts
    get '/:concept/narrower' do
      ont, submission = get_ontology_and_submission
      concept_id = RDF::URI.new(params[:concept])
      error 400, "The input concept id '#{params[:concept]}' is not a valid IRI" unless concept_id.valid?

      ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load(includes_param)
      concept = LinkedData::Models::OntoLex::LexicalConcept.find(concept_id).in(submission).first
      error 404, "LexicalConcept '#{params[:concept]}' not found in ontology #{ont.acronym}" if concept.nil?

      LinkedData::Models::OntoLex::LexicalConcept.in(submission).models([concept]).include(:narrower).all
      narrower = concept.narrower || []
      unless narrower.empty?
        LinkedData::Models::OntoLex::LexicalConcept.in(submission).models(narrower).include(ld).all
      end
      reply narrower
    end
  end
end
