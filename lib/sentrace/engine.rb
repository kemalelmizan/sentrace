module Sentrace
  class Engine < ::Rails::Engine
    isolate_namespace Sentrace
    config.generators.api_only = true

    initializer "sentrace.filter_parameters" do |app|
      app.config.filter_parameters += %i[sentry_secret]
    end
  end
end
