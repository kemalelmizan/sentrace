module Sentrace
  class Engine < ::Rails::Engine
    isolate_namespace Sentrace
    config.generators.api_only = true
  end
end
