class OntoLexSensesController < ApplicationController

  namespace "/ontologies/:ontology/lexical_senses" do

    # List lexical senses for an ontology submission (paged)
    get do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalSense, [ont.acronym])

      page, size = page_params
      ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load(includes_param)
      unmapped = ld.delete(:properties)

      senses = LinkedData::Models::OntoLex::LexicalSense
                  .in(submission)
                  .include(ld)
                  .page(page, size)
                  .all

      if unmapped && senses.length > 0
        LinkedData::Models::OntoLex::LexicalSense.in(submission).models(senses).include(:unmapped).all
      end

      reply senses
    end

    # Get a single lexical sense
    get '/:sense' do
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalSense, [ont.acronym])

      ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load(includes_param)
      unmapped = ld.delete(:properties) || (includes_param && includes_param.include?(:all))

      sense_id = RDF::URI.new(params[:sense])
      error 400, "The input sense id '#{params[:sense]}' is not a valid IRI" unless sense_id.valid?

      sense = LinkedData::Models::OntoLex::LexicalSense
                .find(sense_id)
                .in(submission)
                .include(ld)
                .first

      error 404, "LexicalSense '#{params[:sense]}' not found in ontology #{ont.acronym}" if sense.nil?

      if unmapped
        LinkedData::Models::OntoLex::LexicalSense.in(submission).models([sense]).include(:unmapped).all
      end

      reply sense
    end
  end
end
