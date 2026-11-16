namespace :sentrace do
  desc "Run the Sentrace Model Context Protocol (MCP) server over stdio"
  task mcp: :environment do
    Sentrace::Mcp::StdioRunner.run
  end

  namespace :mcp do
    desc "List all issued Sentrace MCP bearer tokens (prefixes and status only)"
    task tokens: :environment do
      Sentrace::Mcp::TokenManager.new.list
    end

    namespace :tokens do
      desc "Issue a new Sentrace MCP bearer token (stored as SHA-256 digest)"
      task :create, [ :name ] => :environment do |_task, args|
        Sentrace::Mcp::TokenManager.new.create(name: args[:name])
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        abort e.message
      end

      desc "Rotate active Sentrace MCP bearer token(s) for a given name"
      task :rotate, [ :name ] => :environment do |_task, args|
        Sentrace::Mcp::TokenManager.new.rotate(name: args[:name])
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        abort e.message
      end

      desc "Revoke a Sentrace MCP bearer token by numeric ID"
      task :revoke, [ :id ] => :environment do |_task, args|
        Sentrace::Mcp::TokenManager.new.revoke(id: args[:id])
      rescue ArgumentError, Sentrace::Mcp::TokenManager::TokenNotFoundError => e
        abort e.message
      end
    end
  end
end
