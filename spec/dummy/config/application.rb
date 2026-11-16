require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)
require "sentrace"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.api_only = true
    config.root = File.expand_path("..", __dir__)
  end
end
