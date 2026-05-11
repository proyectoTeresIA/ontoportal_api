require 'goo/sparql/client'

module Goo
  module SPARQL
    class Client
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
          joiner = params[:url].include?("?") ? "&" : "?"
          if backend_name.include?("fuseki")
            if graph && !graph.to_s.empty?
              params[:url] << "#{joiner}graph=#{CGI.escape(graph.to_s)}"
            else
              params[:url] << "#{joiner}default"
            end
          else
            params[:url] << "#{joiner}context=#{CGI.escape("<#{graph}>")}"
          end
          params[:payload] = data_file
        end

        RestClient::Request.execute(params)
      end
    end
  end
end