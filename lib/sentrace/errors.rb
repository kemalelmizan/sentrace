module Sentrace
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InvalidDsnError < Error; end
  class EnvelopeParseError < Error; end
  class PayloadTooLargeError < Error; end

  class RateLimitExceededError < Error
    attr_reader :retry_after

    def initialize(message = "Rate limit exceeded", retry_after: 60)
      super(message)
      @retry_after = retry_after.to_i
    end
  end

  class McpError < Error; end
  class McpInvalidParamsError < McpError; end
  class McpNotFoundError < McpError; end
  class McpForbiddenError < McpError; end
  class McpRemoteError < McpError
    attr_reader :environment, :category

    def initialize(message, environment:, category:)
      super(message)
      @environment = environment.to_s
      @category = category.to_s
    end
  end
end
