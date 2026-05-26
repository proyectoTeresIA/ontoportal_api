require 'set'

# Provides a cross-ontology endpoint to retrieve all unique language codes
# from OntoLex submissions. Results are cached in memory.
class OntolexLanguagesController < ApplicationController
  CACHE_TTL = 1800 # 30 minutes in seconds

  @_codes_cache     = nil
  @_codes_cached_at = nil

  class << self
    def get_cached_languages
      now = Time.now
      if @_codes_cache.nil? || (now - @_codes_cached_at) > CACHE_TTL
        @_codes_cache     = compute_all_ontolex_languages
        @_codes_cached_at = now
      end
      @_codes_cache
    end

    def invalidate_cache!
      @_codes_cache     = nil
      @_codes_cached_at = nil
    end

    private

    def compute_all_ontolex_languages
      all_codes = Set.new
      begin
        onts = LinkedData::Models::Ontology.where
                 .include(:acronym)
                 .to_a

        onts.each do |ont|
          begin
            sub = ont.latest_submission(status: [:RDF])
            next unless sub

            sub.bring(hasOntologyLanguage: [:acronym])
            lang = sub.hasOntologyLanguage
            next unless lang.respond_to?(:acronym) &&
                        lang.acronym.to_s.upcase == 'ONTOLEX'

            entries = LinkedData::Models::OntoLex::LexicalEntry
                        .in(sub).include(:language).all
            entries.each do |e|
              uri = e.language&.to_s
              next unless uri
              code = uri.split('/').last.split('#').last
              all_codes.add(code) unless code.empty?
            end
          rescue => _err
            next
          end
        end
      rescue => _err
        # Return empty on unexpected error
      end
      all_codes.to_a.sort
    end
  end

  namespace "/ontolex_languages" do
    get do
      reply OntolexLanguagesController.get_cached_languages
    end
  end
end
