module Sentrace
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InvalidDsnError < Error; end
end
