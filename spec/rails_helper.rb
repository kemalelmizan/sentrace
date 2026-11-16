ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"

abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "factory_bot_rails"

FactoryBot.definition_file_paths = [ File.expand_path("factories", __dir__) ]
FactoryBot.find_definitions

engine_migrations_path = File.expand_path("../db/migrate", __dir__)
migration_paths =
  if ActiveRecord::Migrator.respond_to?(:migrations_paths)
    ActiveRecord::Migrator.migrations_paths
  else
    ActiveRecord::Tasks::DatabaseTasks.migrations_paths
  end

unless migration_paths.any? { |path| File.expand_path(path) == engine_migrations_path }
  migration_paths << engine_migrations_path
end

has_migrations = migration_paths.any? do |path|
  Dir.glob(File.join(path, "*.rb")).any?
end

if has_migrations
  begin
    if ActiveRecord.gem_version >= Gem::Version.new("7.1")
      ActiveRecord::Migration.maintain_test_schema!
    elsif ActiveRecord::MigrationContext.instance_method(:initialize).arity == 1
      ActiveRecord::MigrationContext.new(migration_paths).migrate
    else
      ActiveRecord::MigrationContext.new(migration_paths, ActiveRecord::SchemaMigration).migrate
    end
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
