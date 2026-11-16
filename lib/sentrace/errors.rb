module Sentrace
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InvalidDsnError < Error; end
  class EnvelopeParseError < Error; end
  class PayloadTooLargeError < Error; end
end
