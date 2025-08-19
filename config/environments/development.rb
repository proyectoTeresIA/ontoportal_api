# Load required gems first
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
SOLR_PROP_SEARCH_URL  = ENV.fetch('SOLR_PROP_SEARCH_URL', 'http://localhost:8983/solr/prop_search_core1')
SOLR_TERM_SEARCH_URL  = ENV.fetch('SOLR_TERM_SEARCH_URL', 'http://localhost:8983/solr/term_search_core1')

LinkedData.config do |config|
  config.goo_backend_name              = GOO_BACKEND_NAME.to_s
  config.goo_host                      = GOO_HOST.to_s
  config.goo_port                      = GOO_PORT.to_i
  config.goo_path_query                = GOO_PATH_QUERY.to_s
  config.goo_path_data                 = GOO_PATH_DATA.to_s
  config.goo_path_update               = GOO_PATH_UPDATE.to_s
  config.goo_redis_host                = REDIS_GOO_CACHE_HOST.to_s
  config.goo_redis_port                = REDIS_PORT.to_i
  config.http_redis_host               = REDIS_HTTP_CACHE_HOST.to_s
  config.http_redis_port               = REDIS_PORT.to_i
  config.ontology_analytics_redis_host = REDIS_PERSISTENT_HOST.to_s
  config.ontology_analytics_redis_port = REDIS_PORT.to_i
  config.search_server_url             = SOLR_TERM_SEARCH_URL.to_s
  config.property_search_server_url    = SOLR_PROP_SEARCH_URL.to_s
  config.replace_url_prefix            = true
  config.rest_url_prefix               = REST_URL_PREFIX.to_s
  #  config.enable_notifications          = false
  config.id_url_prefix                 = REST_URL_PREFIX.to_s
end

Annotator.config do |config|
  config.annotator_redis_host  = REDIS_PERSISTENT_HOST.to_s
  config.annotator_redis_port  = REDIS_PORT.to_i
  config.mgrep_host            = MGREP_HOST.to_s
  config.mgrep_port            = MGREP_PORT.to_i
  config.mgrep_dictionary_file = MGREP_DICTIONARY_FILE.to_s
end

LinkedData::OntologiesAPI.config do |config|
  config.http_redis_host = REDIS_HTTP_CACHE_HOST.to_s
  config.http_redis_port = REDIS_PORT.to_i
  #  config.restrict_download = ["ACR0", "ACR1", "ACR2"]
end

NcboCron.config do |config|
  config.redis_host = ENV.fetch("REDIS_HOST", "redis-ut")
  config.redis_port = REDIS_PORT.to_i
  config.ontology_report_path = REPORT_PATH.to_s
  
  # Do not daemonize in Docker
  config.daemonize = false
  
  # Processing intervals - check every minute
  config.minutes_between = 1
end