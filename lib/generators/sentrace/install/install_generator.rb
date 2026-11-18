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

      def create_mcp_binstub
        template "sentrace-mcp.tt", "bin/sentrace-mcp"
        chmod "bin/sentrace-mcp", 0o755, verbose: false
      end

      def display_sdk_instructions
        say "\nSentrace installed!", :green
        say <<~INSTRUCTIONS

          Next steps:
            1. Run migrations:
               bin/rails db:migrate

            2. Bootstrap your initial project (`#{default_project_slug}`):
               bin/rails sentrace:setup

            3. Review native Ruby capture in config/initializers/sentrace.rb:
               # `config.project_slug` enables zero-HTTP in-process capture for Rack/Rails,
               # Sidekiq, and ActiveJob automatically (disabled by default in Rails.env.test?).
               # Optional legacy sentry-ruby migration path:
               #   Sentry.init { |c| c.dsn = ENV["SENTRY_DSN"]; c.transport.transport_class = Sentrace::SentryTransport }

            4. Configure frontend browser & React capture (optional):
               npm install sentrace
               # Same-origin Rails apps auto-resolve the public DSN from `config.project_slug`
               # with zero `SENTRACE_FRONTEND_DSN` env var needed (or call `Sentrace.frontend_dsn(request: request)` in SPA config endpoints).
               # IMPORTANT: In app/views/layouts/application.html.erb <head>, render
               # <%= sentrace_meta_tags %> BEFORE any synchronous <script>,
               # javascript_pack_tag, javascript_include_tag, or yield(:head) tags:
               #   <head>
               #     <%= sentrace_meta_tags %>
               #     <%= javascript_pack_tag "application" %>
               #   </head>
               # In app/javascript/application.js:
               #   import * as Sentrace from "sentrace"
               #   import { ErrorBoundary } from "sentrace/react" # optional React >= 16.8
               #   Sentrace.init()

            5. Connect your AI coding agent via the isolated stdio MCP binstub:
               # Workspace .mcp.json: { "mcpServers": { "sentrace": { "command": "./bin/sentrace-mcp" } } }
               # Global IDE config:   { "mcpServers": { "sentrace": { "command": "#{File.expand_path('bin/sentrace-mcp', destination_root)}" } } }
        INSTRUCTIONS
      end

      private
        def default_project_slug
          app_name = File.basename(destination_root).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
          app_name.empty? ? "app" : app_name
        end
    end
  end
end
