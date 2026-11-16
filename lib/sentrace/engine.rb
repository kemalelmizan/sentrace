module Sentrace
  class Engine < ::Rails::Engine
    isolate_namespace Sentrace
    config.generators.api_only = true

    initializer "sentrace.filter_parameters" do |app|
      app.config.filter_parameters += %i[sentry_secret]
    end

    initializer "sentrace.rack_middleware" do |app|
      if defined?(ActionDispatch::DebugExceptions)
        app.middleware.insert_after ActionDispatch::DebugExceptions, Sentrace::Integrations::RackMiddleware
      else
        app.middleware.use Sentrace::Integrations::RackMiddleware
      end
    rescue RuntimeError
      app.middleware.use Sentrace::Integrations::RackMiddleware
    end

    initializer "sentrace.active_job" do
      ActiveSupport.on_load(:active_job) do
        include Sentrace::Integrations::ActiveJob unless included_modules.include?(Sentrace::Integrations::ActiveJob)
      end
    end

    initializer "sentrace.view_helpers" do
      ActiveSupport.on_load(:action_view) do
        include Sentrace::ViewHelpers
      end
    end

    config.after_initialize do
      Sentrace::Breadcrumbs.apply_configuration!(Sentrace.configuration)
      Sentrace::Integrations::Sidekiq.install! if defined?(::Sidekiq)
    end
  end
end
