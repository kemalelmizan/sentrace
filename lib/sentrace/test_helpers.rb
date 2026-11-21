module Sentrace
  module TestHelpers
    def with_sentrace_test_config(**overrides, &block)
      defaults = { enabled: true, capture_dispatch: :inline, reset_rate_limiter: true }
      Sentrace.with_configuration(**defaults.merge(overrides), &block)
    ensure
      Sentrace.clear_scope!
    end
    alias_method :with_sentrace_configuration, :with_sentrace_test_config

    def reset_sentrace_test_state!
      Sentrace.clear_scope!
      CaptureDispatcher.clear_cache!
      FrontendDsnResolver.clear_cache!
      RateLimiter.reset!
      McpToken.clear_verified_cache! if defined?(McpToken) && McpToken.respond_to?(:clear_verified_cache!)
      Integrations::ExceptionDeduplicator.reset!
    end
  end
end
