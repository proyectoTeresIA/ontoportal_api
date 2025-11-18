require 'cgi'
require_relative 'search_helper'

module Sinatra
  module Helpers
    module LexicalSearchHelper
      # Use the main SearchHelper explicitly (avoid alias/constant load-order issues)
      include Sinatra::Helpers::SearchHelper

      # Lexical-specific parameters
      LANGUAGE_PARAM = "language"
      SUBJECTS_PARAM = "subjects"
      PART_OF_SPEECH_PARAM = "part_of_speech"
      TERM_TYPE_PARAM = "term_type"

      # Build a Solr query for lexical entry search
      # Similar to get_term_search_query but optimized for OntoLex data
      def get_lexical_search_query(text, params={})
        validate_params_solr_population([:lemma, :writtenRep, :definition, :language, :partOfSpeech])

        # Allow empty queries (will be treated as *)
        text = '' if text.nil?

        query = ""
        params["defType"] = "edismax"
        params["stopwords"] = "true"
        params["lowercaseOperators"] = "true"
        params["fl"] = "*,score"

        # Highlighting to determine matched fields
        params["hl"] = "on"
        params["hl.simple.pre"] = Sinatra::Helpers::SearchHelper::MATCH_HTML_PRE
        params["hl.simple.post"] = Sinatra::Helpers::SearchHelper::MATCH_HTML_POST

        # Build query based on exact match or regular search
        if params[Sinatra::Helpers::SearchHelper::EXACT_MATCH_PARAM] == "true"
          query = "\"#{solr_escape(text)}\""
          params["qf"] = "writtenRepExact^100 lemmaExact^90 resource_id^20"
          params["hl.fl"] = "writtenRepExact lemmaExact resource_id"
        elsif params[Sinatra::Helpers::SearchHelper::SUGGEST_PARAM] == "true" || (!text.empty? && text[-1] == '*')
          # Autocomplete/suggest mode
          text.gsub!(/\*+$/, '')
          query = "\"#{solr_escape(text)}\""
          params["qt"] = "/suggest_ncbo"
          params["qf"] = "writtenRepExact^100 writtenRepSuggestEdge^80 lemmaSuggestEdge^70 writtenRepSuggestNgram^30 lemmaSuggestNgram^20"
          params["pf"] = "writtenRepExact^50 lemmaExact^40"
          params["hl.fl"] = "writtenRepExact writtenRepSuggestEdge lemmaSuggestEdge"
        else
          # Regular search - flexible mode with automatic wildcards
          if text.strip.empty? || text == '*'
            query = '*:*'
          else
            # Add wildcards for partial matching if not already present
            search_text = text.strip
            unless search_text.include?('*') || search_text.start_with?('"')
              search_text = "*#{search_text}*"
            end
            query = solr_escape(search_text)
          end
          # Prioritize text_general fields (with ASCII folding) over Exact fields
          params["qf"] = "writtenRep^100 lemma^90 writtenRepExact^80 lemmaExact^70 conceptLabel^30 definition^20 subjectLabel^25 resource_id^50"
          params["hl.fl"] = "writtenRep lemma writtenRepExact lemmaExact conceptLabel definition subjectLabel resource_id"
        end

        # Build filter query
        filter_query = ""

        # Ontology filtering
        if params[Sinatra::Helpers::SearchHelper::ONTOLOGIES_PARAM] && !params[Sinatra::Helpers::SearchHelper::ONTOLOGIES_PARAM].empty?
          acronyms = params[Sinatra::Helpers::SearchHelper::ONTOLOGIES_PARAM].split(",").map(&:strip)
          if acronyms.length > 1
            filter_query = "submissionAcronym:(#{acronyms.join(' OR ')})"
          else
            filter_query = "submissionAcronym:#{acronyms.first}"
          end
        end

        # Language filtering
        if params[LANGUAGE_PARAM] && !params[LANGUAGE_PARAM].empty?
          lang_clause = "language:#{params[LANGUAGE_PARAM]}"
          filter_query = filter_query.empty? ? lang_clause : "#{filter_query} AND #{lang_clause}"
        end

        # Subject/domain filtering
        if params[SUBJECTS_PARAM] && !params[SUBJECTS_PARAM].empty?
          subjects = params[SUBJECTS_PARAM].split(",").map(&:strip)
          subject_clause = subjects.length > 1 ? "subject:(#{subjects.join(' OR ')})" : "subject:#{subjects.first}"
          filter_query = filter_query.empty? ? subject_clause : "#{filter_query} AND #{subject_clause}"
        end

        # Part of speech filtering - support both URI and simple label
        if params[PART_OF_SPEECH_PARAM] && !params[PART_OF_SPEECH_PARAM].empty?
          pos_value = params[PART_OF_SPEECH_PARAM].strip
          # If it looks like a simple label (e.g., "noun"), search in both fields
          if pos_value.include?('#') || pos_value.include?('/')
            # It's a URI or fragment, search exact
            pos_clause = "partOfSpeech:#{pos_value}"
          else
            # Simple label - search in both partOfSpeech (URI) and partOfSpeechLabel
            pos_clause = "(partOfSpeech:*#{pos_value}* OR partOfSpeechLabel:#{pos_value})"
          end
          filter_query = filter_query.empty? ? pos_clause : "#{filter_query} AND #{pos_clause}"
        end

        # Term type filtering
        if params[TERM_TYPE_PARAM] && !params[TERM_TYPE_PARAM].empty?
          type_clause = "termType:#{params[TERM_TYPE_PARAM]}"
          filter_query = filter_query.empty? ? type_clause : "#{filter_query} AND #{type_clause}"
        end

        # Add filter query if not empty
        params["fq"] = filter_query unless filter_query.empty?

        query
      end
    end
  end
end

helpers Sinatra::Helpers::LexicalSearchHelper
