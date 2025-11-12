require "cgi"

class LexicalSensesController < ApplicationController
  namespace "/ontologies/:ontology/lexical_senses" do
    get do
      includes_param_check(LinkedData::Models::OntoLex::LexicalSense)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalSense, [ont.acronym])

      page, size = page_params
      total = LinkedData::Models::OntoLex::LexicalSense.count_in_submission(submission)
      ld = LinkedData::Models::OntoLex::LexicalSense.goo_attrs_to_load([:all])
      items = LinkedData::Models::OntoLex::LexicalSense.list_in_submission(submission, page, size, ld)
      items.each { |it| it.ensure_computed rescue nil }
      reply page_object(items, total)
    end

    get "/*" do
      includes_param_check(LinkedData::Models::OntoLex::LexicalSense)
      ont, submission = get_ontology_and_submission
      check_last_modified_segment(LinkedData::Models::OntoLex::LexicalSense, [ont.acronym])

      id = params[:splat].is_a?(Array) ? params[:splat].first : params[:splat]
      id = normalize_iri(id)
      
      # Always use enriched read_only built with the same logic used by the list endpoint
      sense = LinkedData::Models::OntoLex::LexicalSense.list_for_ids(submission, [id]).first
      error 404, "LexicalSense not found: #{id}" if sense.nil?
      sense.ensure_computed rescue nil
      reply sense
    end

    private

    def includes_param_check(klass)
      if includes_param && !includes_param.empty?
        allowed = klass.attributes + [:all]
        leftover = includes_param - allowed
        error(400, "Invalid include params: #{leftover.join(", ")}") unless leftover.empty?
      end
    end

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
  end
end
