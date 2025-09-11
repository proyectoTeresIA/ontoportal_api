#!/usr/bin/env bash
cd /srv/ontoportal/ontologies_api

# Configure bundle
bundle config set --local path /srv/ontoportal/bundle

# Install gems quietly
bundle install --quiet

# Find the ncbo_cron executable path
NCBO_CRON_PATH=$(find /srv/ontoportal/bundle -name ncbo_cron -type f | head -1)

echo "Starting ncbo_cron with minimal API initialization..."

# Create a minimal wrapper that only loads what ncbo_cron needs
cat > /tmp/ncbo_cron_minimal_wrapper.rb << 'EOF'
#!/usr/bin/env ruby

# Load bundler setup
require 'bundler/setup'

# Load only the essential libraries that define LinkedData::OntologiesAPI
require 'ontologies_linked_data'

# Create a minimal LinkedData module structure if not already defined
unless defined?(LinkedData::OntologiesAPI)
  module LinkedData
    module OntologiesAPI
      def self.config
        yield self if block_given?
      end
      
      def self.method_missing(method, *args, &block)
        # Stub for configuration methods
      end
    end
  end
end

# Now load and run ncbo_cron
load ARGV[0]
EOF

# Ensure the log directory and file exist before tailing
mkdir -p /srv/ontoportal/ontologies_api/log
touch /srv/ontoportal/ontologies_api/log/scheduler.log

# Execute the minimal wrapper with the ncbo_cron path
bundle exec ruby /tmp/ncbo_cron_minimal_wrapper.rb "$NCBO_CRON_PATH" --log-level info & tail -f /srv/ontoportal/ontologies_api/log/scheduler.log

echo "ncbo_cron started"