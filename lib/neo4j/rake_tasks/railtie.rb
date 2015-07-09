require 'active_support/notifications'
require 'rails/railtie'

module Neo4j
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load 'neo4j/rake_tasks/neo4j_server.rake'
    end
  end
end
