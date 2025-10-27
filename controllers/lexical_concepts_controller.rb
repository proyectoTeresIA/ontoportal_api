require 'cgi'
class LexicalConceptsController < ApplicationController

  namespace "/ontologies/:ontology/lexical_concepts" do

    get do
      includes_param_check(LinkedData::Models::OntoLex::LexicalConcept)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalConcept, [ont.acronym])

      page, size = page_params
      total = LinkedData::Models::OntoLex::LexicalConcept.count_in_submission(submission)
      ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load([:all])
      items = LinkedData::Models::OntoLex::LexicalConcept.list_in_submission(submission, page, size, ld)
      reply page_object(items, total)
    end

    get '/*' do
      includes_param_check(LinkedData::Models::OntoLex::LexicalConcept)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalConcept, [ont.acronym])

  # Load enriched read_only using the same logic as list for parity
  ld = LinkedData::Models::OntoLex::LexicalConcept.goo_attrs_to_load([:all])
      id = params[:splat].is_a?(Array) ? params[:splat].first : params[:splat]
      id = normalize_iri(id)
      rid = begin
        RDF::URI(id.to_s)
      rescue StandardError
        nil
      end
  error 404, "LexicalConcept not found: #{id}" unless rid && rid.to_s.start_with?("http")
      concept = LinkedData::Models::OntoLex::LexicalConcept.list_for_ids(submission, [rid], ld).first
      error 404, "LexicalConcept not found: #{id}" unless concept
      reply concept
    end

    private
    def normalize_iri(raw)
      val = raw.to_s
      2.times do
        begin
          decoded = CGI.unescape(val)
          val = decoded if decoded && decoded != val
        rescue StandardError
          break
        end
      end
      val = val.sub(/^(https?):\/(?!\/)/, '\1://')
      val
    end

    def includes_param_check(klass)
      if includes_param && !includes_param.empty?
        allowed = klass.attributes + [:all]
        leftover = includes_param - allowed
        error(400, "Invalid include params: #{leftover.join(', ')}") unless leftover.empty?
      end
    end
    end
end
