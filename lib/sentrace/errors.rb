module Sentrace
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InvalidDsnError < Error; end
  class EnvelopeParseError < Error; end
  class PayloadTooLargeError < Error; end

  class McpError < Error; end
  class McpInvalidParamsError < McpError; end
  class McpNotFoundError < McpError; end
  class McpRemoteError < McpError
    attr_reader :environment, :category

    def initialize(message, environment:, category:)
      super(message)
      @environment = environment.to_s
      @category = category.to_s
    end
  end
end
