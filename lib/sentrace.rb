require "logger"
require "sentrace/version"
require "sentrace/errors"
require "sentrace/configuration"
require "sentrace/request_security"
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
require "sentrace/frontend_dsn_resolver"
require "sentrace/view_helpers"
require "sentrace/test_helpers"
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
      FrontendDsnResolver.clear_cache!
      Breadcrumbs.reset! if defined?(Breadcrumbs) && Breadcrumbs.respond_to?(:reset!)
      @configuration = Configuration.new
    end

    def with_configuration(**overrides)
      raise ArgumentError, "Sentrace.with_configuration requires a block" unless block_given?

      previous_config = configuration.dup
      previous_stack = Thread.current[Scope::SCOPE_STACK_KEY]&.map(&:deep_clone)
      begin
        isolated_config = previous_config.dup
        overrides.each do |key, value|
          setter = :"#{key}="
          unless isolated_config.respond_to?(setter)
            raise ConfigurationError, "Unknown configuration attribute #{key.inspect}"
          end
          isolated_config.public_send(setter, value)
        end
        isolated_config.validate!
        @configuration = isolated_config
        CaptureDispatcher.clear_cache!
        FrontendDsnResolver.clear_cache!
        Integrations::ExceptionDeduplicator.reset!
        Scope.clear!
        Breadcrumbs.apply_configuration!(isolated_config) if defined?(Breadcrumbs) && Breadcrumbs.respond_to?(:apply_configuration!)
        yield(isolated_config)
      ensure
        @configuration = previous_config
        CaptureDispatcher.clear_cache!
        FrontendDsnResolver.clear_cache!
        Integrations::ExceptionDeduplicator.reset!
        if previous_stack
          Thread.current[Scope::SCOPE_STACK_KEY] = previous_stack
        else
          Scope.clear!
        end
        Breadcrumbs.apply_configuration!(previous_config) if defined?(Breadcrumbs) && Breadcrumbs.respond_to?(:apply_configuration!)
      end
    end

    def resolve_frontend_dsn(base_url:, project: nil)
      FrontendDsnResolver.resolve(base_url: base_url, project: project)
    end

    def frontend_dsn(base_url: nil, request: nil, project: nil)
      FrontendDsnResolver.resolve(base_url: base_url, request: request, project: project)
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
