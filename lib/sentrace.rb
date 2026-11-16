require "sentrace/version"
require "sentrace/errors"
require "sentrace/configuration"
require "sentrace/dsn"
require "sentrace/project_manager"
require "sentrace/ingestion/envelope_parser"
require "sentrace/ingestion/event_normalizer"
require "sentrace/ingestion/sanitizer"
require "sentrace/issues/fingerprint"
require "sentrace/issues/grouper"
require "sentrace/ingestion/processor"
require "sentrace/mcp/local_backend"
require "sentrace/mcp/token_manager"
require "sentrace/mcp/remote_http_client"
require "sentrace/mcp/environment_router"
require "sentrace/mcp/dispatcher"
require "sentrace/mcp/server"
require "sentrace/mcp/stdio_runner"
require "sentrace/engine"

module Sentrace
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
      configuration.validate!
      configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
