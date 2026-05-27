# Extension to NcboAnnotator to support OntoLex entities
# This file adds indexing capabilities for OntoLex Forms and LexicalConcepts

puts "[OntoLex Extension] Loading ncbo_annotator_ontolex_extension.rb"

module Annotator
  module Models
    class NcboAnnotator
      
      # Override create_term_cache_for_submission to support OntoLex
      alias_method :original_create_term_cache_for_submission, :create_term_cache_for_submission
      
      def create_term_cache_for_submission(logger, sub, redis=nil, redis_prefix=nil)
        # Set admin user context so sub.save() inside the original method has write access
        original_user = Thread.current[:remote_user]
        unless original_user
          begin
            admin = LinkedData::Models::User.where(role: LinkedData::Models::Users::Role.find("ADMINISTRATOR").first).include(:username, :role).first
            Thread.current[:remote_user] = admin if admin
          rescue => e
            logger.warn("Could not set admin user for annotator cache: #{e.message}")
          end
        end

        begin
          # Call original method for standard ontologies
          original_create_term_cache_for_submission(logger, sub, redis, redis_prefix)
        ensure
          Thread.current[:remote_user] = original_user
        end
        
        # Check if this is an OntoLex ontology
        sub.bring(:hasOntologyLanguage) if sub.bring?(:hasOntologyLanguage)
        ont_lang = sub.hasOntologyLanguage
        
        # hasOntologyLanguage is an OntologyFormat object with an ID (URI)
        # The ID will be something like http://api:9393/ontology_formats/ONTOLEX
        is_ontolex = ont_lang && ont_lang.id.to_s.include?('ONTOLEX')
        
        logger.info("Checking ontology language: #{ont_lang.inspect} (ID: #{ont_lang&.id})")
        
        if is_ontolex
          logger.info("✓ OntoLex ontology detected! Creating term cache for OntoLex entities...")
          create_ontolex_term_cache(logger, sub, redis, redis_prefix)

          # Regenerate the dictionary after parsing to ensure OntoLex entries become 
          # available to mgrep immediately instead of waiting for the scheduled job.
          if redis.nil?
            begin
              cron_settings = defined?(::NcboCron) && ::NcboCron.respond_to?(:settings) ? ::NcboCron.settings : nil
              if cron_settings && cron_settings.respond_to?(:enable_dictionary_generation_cron_job) && cron_settings.enable_dictionary_generation_cron_job
                logger.info("Regenerating mgrep dictionary after OntoLex cache update (cron job enabled)...")
                generate_dictionary_file()
                logger.info("Completed mgrep dictionary regeneration after OntoLex cache update.")
              else
                logger.info("Skipping immediate dictionary regeneration (cron job disabled or unavailable).")
              end
            rescue Exception => e
              logger.error("Failed regenerating mgrep dictionary after OntoLex cache update: #{e.message}")
            end
          end
        else
          logger.info("✗ Not an OntoLex ontology (language: #{ont_lang&.id}), skipping OntoLex indexing")
        end
      end
      
      private

      def create_ontolex_term_cache(logger, sub, redis = nil, redis_prefix = nil)
        return logger.error("Error from create_ontolex_term_cache: submission is nil") if sub.nil?

        multi_logger = LinkedData::Utils::MultiLogger.new(loggers: logger)
        begin
          multi_logger.add_logger(Logger.new(sub.parsing_log_path))
        rescue StandardError
          # If log file creation fails, continue with just the primary logger
        end

        redis        ||= redis()
        redis_prefix ||= redis_current_instance()

        begin
          time = Benchmark.realtime do
            sub.ontology.bring(:acronym) if sub.ontology.bring?(:acronym)
            ontResourceId = sub.ontology.id.to_s
            multi_logger.info("Caching OntoLex forms for #{sub.ontology.acronym}")

            # ── Step 1: Load ALL LexicalEntries in one SPARQL query ─────────────
            # Builds a form_uri → concept_id reverse map without any per-form
            # round-trips.
            t0 = Time.now
            all_entries = LinkedData::Models::OntoLex::LexicalEntry.in(sub)
                              .include(:evokes, :canonicalForm, :form, :otherForm, :sense)
                              .all
            multi_logger.info("Loaded #{all_entries.length} entries in #{(Time.now - t0).round(2)}s")

            form_to_entry  = {}  # form_uri_string → entry_uri_string (stored in Redis as class_id)
            sense_entry_map = {}  # sense_uri_string → entry (resolved in step 2)

            all_entries.each do |entry|
              concept_id = entry.evokes.is_a?(Array) ? entry.evokes.first : entry.evokes

              if concept_id
                [entry.canonicalForm,
                 *Array(entry.form),
                 *Array(entry.otherForm)].compact.each do |fid|
                  form_to_entry[fid.to_s] ||= entry.id.to_s
                end
              elsif entry.sense
                Array(entry.sense).compact.each { |sid| sense_entry_map[sid.to_s] = entry }
              end
            end

            # ── Step 2: Resolve senses in one SPARQL query ───────────────────────
            if sense_entry_map.any?
              t0 = Time.now
              all_senses = LinkedData::Models::OntoLex::LexicalSense.in(sub)
                               .include(:isLexicalizedSenseOf)
                               .all
              multi_logger.info("Loaded #{all_senses.length} senses in #{(Time.now - t0).round(2)}s")

              all_senses.each do |sense|
                next unless sense.isLexicalizedSenseOf
                entry = sense_entry_map[sense.id.to_s]
                next unless entry

                [entry.canonicalForm,
                 *Array(entry.form),
                 *Array(entry.otherForm)].compact.each do |fid|
                  form_to_entry[fid.to_s] ||= entry.id.to_s
                end
              end
            end

            multi_logger.info("form→entry map: #{form_to_entry.size} mappings from #{all_entries.length} entries")

            # ── Step 3: Page through Forms and index writtenRep values ───────────
            # Strips HTML tags so "<i>Leishmania</i>" indexes as "Leishmania".
            count_indexed = 0
            lex_page = 1
            lex_size = 1000

            loop do
              t0 = Time.now
              forms = LinkedData::Models::OntoLex::Form.in(sub)
                          .include(:writtenRep)
                          .page(lex_page, lex_size)
                          .all
              break if forms.empty?

              forms.each do |form|
                next unless form.writtenRep

                entry_id = form_to_entry[form.id.to_s]
                next unless entry_id

                # Strip HTML tags (e.g. <i>term</i> → term)
                written_rep = form.writtenRep.to_s.gsub(/<[^>]+>/, '').strip
                next if written_rep.empty?

                create_term_entry(
                  redis, redis_prefix, ontResourceId, entry_id,
                  Annotator::Annotation::MATCH_TYPES[:type_preferred_name],
                  written_rep, []
                )
                count_indexed += 1
              end

              multi_logger.info("Page #{lex_page}: #{forms.length} forms, #{count_indexed} indexed so far (#{(Time.now - t0).round(2)}s)")
              break unless forms.next?
              lex_page += 1
            end

            multi_logger.info("Indexed #{count_indexed} OntoLex form entries for #{sub.ontology.acronym}.")
          end

          multi_logger.info("Completed OntoLex annotator cache for #{sub.ontology.acronym} (#{sub.id}) in #{time.round(2)}s")
        rescue Exception => e
          multi_logger.error("Failed caching OntoLex entries for #{sub.ontology.acronym} (#{sub.id})")
          multi_logger.error("#{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}")
        ensure
          multi_logger.flush
        end
      end
      
    end
  end
end
