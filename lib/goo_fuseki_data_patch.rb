require 'goo/sparql/client'
require 'uri'

module Goo
  module SPARQL
    class Client
      # Fuseki does not support the custom `rules` query parameter used by other backends.
      # Strip it to avoid per-request warnings and unnecessary query-string noise.
      unless method_defined?(:query_without_fuseki_rules_patch)
        alias_method :query_without_fuseki_rules_patch, :query

        def query(query_string = nil, options = {}, &block)
          backend_name = Goo.sparql_backend_name.to_s.downcase
          if backend_name.include?("fuseki") && options.is_a?(Hash)
            query_options = options[:query_options]
            if query_options.is_a?(Hash)
              clean_query_options = query_options.dup
              clean_query_options.delete(:rules)
              clean_query_options.delete('rules')

              clean_options = options.dup
              clean_options[:query_options] = clean_query_options
              options = clean_options
            end
          end

          query_without_fuseki_rules_patch(query_string, options, &block)
        end
      end

      private

      # Fuseki requires either ?graph=... or ?default for /data POST requests.
      # Goo appends ?context=... for non-4store backends, which Fuseki rejects.
      def execute_append_request(graph, data_file, mime_type_in)
        mime_type = "text/turtle"

        if mime_type_in == "text/x-nquads"
          mime_type = "text/x-nquads"
          graph = "http://data.bogus.graph/uri"
        end

        params = {
          method: :post,
          url: url.to_s,
          headers: { "content-type" => mime_type, "mime-type" => mime_type },
          timeout: nil
        }

        backend_name = Goo.sparql_backend_name.to_s.downcase

        if backend_name == BACKEND_4STORE
          params[:payload] = {
            graph: graph.to_s,
            data: data_file,
            'mime-type' => mime_type
          }
          params[:payload][:data] = params[:payload][:data].split("\n").map { |x| x.sub("\\\\", "") }.join("\n")
        else
          if backend_name.include?("fuseki")
            uri = URI.parse(params[:url])
            query_parts = uri.query.to_s.split('&').reject(&:empty?)
            query_parts.reject! { |q| q == 'default' || q.start_with?('graph=') || q.start_with?('context=') }

            if graph && !graph.to_s.empty?
              query_parts << "graph=#{CGI.escape(graph.to_s)}"
            else
              query_parts << 'default'
            end

            uri.query = query_parts.empty? ? nil : query_parts.join('&')
            params[:url] = uri.to_s
          else
            joiner = params[:url].include?("?") ? "&" : "?"
            params[:url] << "#{joiner}context=#{CGI.escape("<#{graph}>")}"
          end
          params[:payload] = data_file
        end

        RestClient::Request.execute(params)
      end
    end
  end
end