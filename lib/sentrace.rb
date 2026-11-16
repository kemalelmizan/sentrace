require "sentrace/version"
require "sentrace/errors"
require "sentrace/configuration"
require "sentrace/dsn"
require "sentrace/project_manager"
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
