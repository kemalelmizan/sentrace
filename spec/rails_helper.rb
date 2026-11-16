ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"

abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "factory_bot_rails"

FactoryBot.definition_file_paths = [ File.expand_path("factories", __dir__) ]
FactoryBot.find_definitions

engine_migrations_path = File.expand_path("../db/migrate", __dir__)
unless ActiveRecord::Migrator.migrations_paths.any? { |path| File.expand_path(path) == engine_migrations_path }
  ActiveRecord::Migrator.migrations_paths << engine_migrations_path
end

has_migrations = ActiveRecord::Migrator.migrations_paths.any? do |path|
  Dir.glob(File.join(path, "*.rb")).any?
end

if has_migrations
  begin
    ActiveRecord::Migration.maintain_test_schema!
  rescue ActiveRecord::PendingMigrationError => e
    abort e.to_s.strip
  end
end

RSpec.configure do |config|
  config.use_transactional_fixtures = has_migrations
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
end
