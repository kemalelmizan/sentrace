require "rails/generators"
require "securerandom"
require "fileutils"

module Sentrace
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Installs Sentrace initializer, route mount, engine migrations, and project setup task."

      def create_initializer
        template "initializer.rb.tt", "config/initializers/sentrace.rb"
      end

      def mount_engine
        routes_path = File.join(destination_root, "config/routes.rb")
        return unless File.exist?(routes_path)

        content = File.read(routes_path)
        return if content.include?("Sentrace::Engine")

        route 'mount Sentrace::Engine => "/sentrace"'
      end

      def copy_engine_migrations
        source_migrations_dir = Sentrace::Engine.root.join("db/migrate")
        target_migrations_dir = File.join(destination_root, "db/migrate")
        FileUtils.mkdir_p(target_migrations_dir)

        existing_suffixes = Dir.glob(File.join(target_migrations_dir, "*.rb")).map do |file|
          File.basename(file).sub(/\A\d+_/, "")
        end

        timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S").to_i

        Dir.glob(File.join(source_migrations_dir, "*.rb")).sort.each do |source_file|
          suffix = File.basename(source_file).sub(/\A\d+_/, "")
          if existing_suffixes.include?(suffix)
            say_status :identical, "db/migrate/#{suffix}", :blue
            next
          end

          timestamp += 1
          target_rel = "db/migrate/#{timestamp}_#{suffix}"
          create_file target_rel, File.read(source_file)
        end
      end

      def create_project_setup_task
        template "sentrace_setup.rake.tt", "lib/tasks/sentrace_setup.rake"
      end

      def display_sdk_instructions
        sample_dsn = Dsn.build(
          base_url: "http://localhost:3000/sentrace",
          public_key: generated_public_key,
          project_id: 1
        )

        say "\nSentrace installed!", :green
        say <<~INSTRUCTIONS

          Next steps:
            1. Run migrations:
               bin/rails db:migrate

            2. Bootstrap your initial project and local DSN:
               bin/rails sentrace:setup

            3. Configure sentry-ruby (e.g. config/initializers/sentry.rb):
               Sentry.init do |config|
                 config.dsn = ENV.fetch("SENTRY_DSN", "#{sample_dsn}")
                 config.environment = Rails.env
                 config.release = ENV["APP_RELEASE"]
               end
        INSTRUCTIONS
      end

      private
        def generated_public_key
          @generated_public_key ||= SecureRandom.hex(16)
        end

        def default_project_slug
          app_name = File.basename(destination_root).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
          app_name.empty? ? "app" : app_name
        end
    end
  end
end
