require "logger"
require "sentrace/version"
require "sentrace/errors"
require "sentrace/configuration"
require "sentrace/dsn"
require "sentrace/project_manager"
require "sentrace/bootstrapper"
require "sentrace/breadcrumb"
require "sentrace/scope"
require "sentrace/event_builder"
require "sentrace/async_worker"
require "sentrace/capture_dispatcher"
require "sentrace/breadcrumbs"
require "sentrace/integrations/exception_deduplicator"
require "sentrace/integrations/rack_middleware"
require "sentrace/integrations/sidekiq"
require "sentrace/integrations/active_job"
require "sentrace/ingestion/envelope_parser"
require "sentrace/ingestion/event_normalizer"
require "sentrace/ingestion/sanitizer"
require "sentrace/issues/fingerprint"
require "sentrace/issues/grouper"
require "sentrace/ingestion/processor"
require "sentrace/retention/cleaner"
require "sentrace/storage_stats"
require "sentrace/benchmark/storage_runner"
require "sentrace/mcp/local_backend"
require "sentrace/mcp/token_manager"
require "sentrace/mcp/remote_http_client"
require "sentrace/mcp/environment_router"
require "sentrace/mcp/dispatcher"
require "sentrace/mcp/server"
require "sentrace/mcp/stdio_runner"
require "sentrace/view_helpers"
require "sentrace/engine"

module Sentrace
  autoload :SentryTransport, "sentrace/sentry_transport"

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
      configuration.validate!
      CaptureDispatcher.clear_cache!
      Breadcrumbs.apply_configuration!(configuration) if defined?(Breadcrumbs) && Breadcrumbs.respond_to?(:apply_configuration!)
      configuration
    end

    def reset_configuration!
      CaptureDispatcher.clear_cache!
      Breadcrumbs.reset! if defined?(Breadcrumbs) && Breadcrumbs.respond_to?(:reset!)
      @configuration = Configuration.new
    end

    def current_scope
      Scope.current
    end

    def with_scope(&block)
      Scope.with_scope(&block)
    end

    def configure_scope(&block)
      Scope.configure_scope(&block)
    end

    def clear_scope!
      Scope.clear!
    end

    def capture_exception(exception, **options)
      CaptureDispatcher.capture_exception(exception, **options)
    end

    def capture_message(message, level: :info, **options)
      CaptureDispatcher.capture_message(message, level: level, **options)
    end

    def add_breadcrumb(crumb_or_hash = nil, **kwargs)
      current_scope.add_breadcrumb(crumb_or_hash, max_breadcrumbs: configuration.max_breadcrumbs, **kwargs)
    end

    def set_tag(key, value)
      current_scope.set_tag(key, value)
    end

    def set_tags(tags_hash)
      current_scope.set_tags(tags_hash)
    end

    def set_user(user_hash_or_nil)
      current_scope.set_user(user_hash_or_nil)
    end

    def set_context(name, context_hash)
      current_scope.set_context(name, context_hash)
    end

    def set_extra(key, value)
      current_scope.set_extra(key, value)
    end

    def set_extras(extras_hash)
      current_scope.set_extras(extras_hash)
    end

    def flush(timeout: 2.0)
      AsyncWorker.default.flush(timeout: timeout)
    end
  end
end
