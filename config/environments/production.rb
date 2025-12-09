require 'ontologies_linked_data'
require 'ncbo_annotator'
require 'ncbo_cron'

GOO_BACKEND_NAME = ENV.fetch('GOO_BACKEND_NAME', '4store')
GOO_HOST         = ENV.fetch('GOO_HOST', 'localhost')
GOO_PATH_DATA    = ENV.fetch('GOO_PATH_DATA', '/data/')
GOO_PATH_QUERY   = ENV.fetch('GOO_PATH_QUERY', '/sparql/')
GOO_PATH_UPDATE  = ENV.fetch('GOO_PATH_UPDATE', '/update/')
GOO_PORT         = ENV.fetch('GOO_PORT', '9000').to_i
MGREP_HOST       = ENV.fetch('MGREP_HOST', 'localhost')
MGREP_PORT       = ENV.fetch('MGREP_PORT', '55555').to_i
MGREP_DICTIONARY_FILE = ENV.fetch('MGREP_DICTIONARY_FILE', './test/data/dictionary.txt')
REDIS_GOO_CACHE_HOST  = ENV.fetch('REDIS_GOO_CACHE_HOST', 'localhost')
REDIS_HTTP_CACHE_HOST = ENV.fetch('REDIS_HTTP_CACHE_HOST', 'localhost')
REDIS_PERSISTENT_HOST = ENV.fetch('REDIS_PERSISTENT_HOST', 'localhost')
REDIS_PORT            = ENV.fetch('REDIS_PORT', '6379').to_i
REPORT_PATH           = ENV.fetch('REPORT_PATH', './test/ontologies_report.json')
REPOSITORY_FOLDER     = ENV.fetch('REPOSITORY_FOLDER', './test/data/ontology_files/repo')
REST_URL_PREFIX       = ENV.fetch('REST_URL_PREFIX', 'http://localhost:9393')
ID_URL_PREFIX         = ENV.fetch('ID_URL_PREFIX', ENV.fetch('REST_URL_PREFIX', 'http://localhost:9393'))
UI_URL                = ENV.fetch('UI_URL', 'http://localhost:3000')
SOLR_PROP_SEARCH_URL  = ENV.fetch('SOLR_PROP_SEARCH_URL', 'http://localhost:8983/solr/prop_search_core1')
SOLR_TERM_SEARCH_URL  = ENV.fetch('SOLR_TERM_SEARCH_URL', 'http://localhost:8983/solr/term_search_core1')
SOLR_LEX_SEARCH_URL   = ENV.fetch('SOLR_LEXICAL_SEARCH_URL', 'http://localhost:8983/solr/lexical_search_core1')

LinkedData.config do |config|
  config.goo_host                      = GOO_HOST.to_s
  config.goo_port                      = GOO_PORT.to_i
  config.goo_backend_name              = GOO_BACKEND_NAME.to_s
  config.goo_path_query                = GOO_PATH_QUERY.to_s
  config.goo_path_data                 = GOO_PATH_DATA.to_s
  config.goo_path_update               = GOO_PATH_UPDATE.to_s
  
  config.rest_url_prefix               = REST_URL_PREFIX.to_s
  config.ui_host                       = UI_URL.to_s
  config.search_server_url             = SOLR_TERM_SEARCH_URL.to_s
  config.property_search_server_url    = SOLR_PROP_SEARCH_URL.to_s
  config.lexical_search_server_url     = SOLR_LEX_SEARCH_URL.to_s
  config.repository_folder             = REPOSITORY_FOLDER.to_s
  config.replace_url_prefix            = true
  config.enable_security               = true
  config.enable_slices                 = true

  # Caches
  Goo.use_cache                        = false
  config.goo_redis_host                = REDIS_GOO_CACHE_HOST.to_s
  config.goo_redis_port                = REDIS_PORT.to_i
  config.enable_http_cache             = false
  config.http_redis_host               = REDIS_HTTP_CACHE_HOST.to_s
  config.http_redis_port               = REDIS_PORT.to_i

  # PURL server config parameters
  config.enable_purl                   = false
  config.purl_host                     = "purl.example.org"
  config.purl_port                     = 80
  config.purl_username                 = "admin"
  config.purl_password                 = "password"
  config.purl_maintainers              = "admin"
  config.purl_target_url_prefix        = "http://example.org"

  # Email notifications
  config.enable_notifications          = true
  config.email_sender                  = "notifications@test.com" # Default sender for emails
  config.email_override                = "notifications@test.com" # all email gets sent here. Disable with email_override_disable.
  config.email_disable_override        = true
  config.smtp_host                     = "smtp.lirmm.fr"
  config.smtp_port                     = 25
  config.smtp_auth_type                = :none # :none, :plain, :login, :cram_md5
  config.smtp_domain                   = "lirmm.fr"
  # Emails of the instance administrators to get mail notifications when new user or new ontology
  config.admin_emails                  = []

  # Ontology Google Analytics Redis
  config.ontology_analytics_redis_host = REDIS_PERSISTENT_HOST.to_s
  config.ontology_analytics_redis_port = REDIS_PORT.to_i

  config.id_url_prefix                 = ID_URL_PREFIX.to_s
end

Annotator.config do |config|
  config.annotator_redis_host  = REDIS_PERSISTENT_HOST.to_s
  config.annotator_redis_port  = REDIS_PORT.to_i
  config.mgrep_host            = MGREP_HOST.to_s
  config.mgrep_port            = MGREP_PORT.to_i
  config.mgrep_dictionary_file = MGREP_DICTIONARY_FILE.to_s
  config.stop_words_default_file = './config/default_stop_words.txt'
  config.mgrep_alt_host          = 'localhost'
end

LinkedData::OntologiesAPI.config do |config|
  config.http_redis_host = REDIS_HTTP_CACHE_HOST.to_s
  config.http_redis_port = REDIS_PORT.to_i
  #  config.restrict_download = ["ACR0", "ACR1", "ACR2"]
  config.enable_unicorn_workerkiller = true
  config.enable_throttling           = false
  config.restrict_download           = []
  #config.ontology_rank               = ""
end

NcboCron.config do |config|
  config.redis_host = ENV.fetch("REDIS_HOST", "redis-ut")
  config.redis_port = REDIS_PORT.to_i
  config.ontology_report_path = REPORT_PATH.to_s
  
  # Do not daemonize in Docker
  config.daemonize = false
  
  # Processing intervals - check every minute
  config.minutes_between = 1

  config.enable_ontology_analytics = true
  config.search_index_all_url = 'http://localhost:8983/solr/term_search_core2'
  config.property_search_server_index_all_url = 'http://localhost:8983/solr/prop_search_core2'
  config.ontology_report_path = "#{$DATADIR}/reports/ontologies_report.json"
  config.enable_spam_deletion = false
  config.enable_dictionary_generation_cron_job = true
  config.cron_dictionary_generation_cron_job = "30 3 * * *"
end