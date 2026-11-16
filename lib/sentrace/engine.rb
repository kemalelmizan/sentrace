module Sentrace
  class Engine < ::Rails::Engine
    isolate_namespace Sentrace
    config.generators.api_only = true

    initializer "sentrace.filter_parameters" do |app|
      app.config.filter_parameters += %i[sentry_secret]
    end

    initializer "sentrace.view_helpers" do
      ActiveSupport.on_load(:action_view) do
        include Sentrace::ViewHelpers
      end
    end
  end
end
