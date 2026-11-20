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
        read_only = ENV["READ_ONLY"].to_s.casecmp("true").zero?
        admin_flag = ENV["ADMIN"].to_s.casecmp("true").zero?
        scopes = ENV["SCOPES"]&.strip
        scopes = "read,write,admin" if (scopes.nil? || scopes.empty?) && admin_flag && !read_only
        expires_in_days = ENV["EXPIRES_IN_DAYS"]&.strip
        expires_in = expires_in_days && !expires_in_days.empty? ? Integer(expires_in_days, 10).days : nil

        Sentrace::Mcp::TokenManager.new.create(
          name: args[:name],
          expires_in: expires_in,
          scopes: scopes.presence,
          read_only: read_only
        )
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        abort e.message
      end

      desc "Rotate active Sentrace MCP bearer token(s) for a given name"
      task :rotate, [ :name ] => :environment do |_task, args|
        read_only = ENV["READ_ONLY"].to_s.casecmp("true").zero?
        admin_flag = ENV["ADMIN"].to_s.casecmp("true").zero?
        scopes = ENV["SCOPES"]&.strip
        scopes = "read,write,admin" if (scopes.nil? || scopes.empty?) && admin_flag && !read_only
        expires_in_days = ENV["EXPIRES_IN_DAYS"]&.strip
        expires_in = expires_in_days && !expires_in_days.empty? ? Integer(expires_in_days, 10).days : nil

        Sentrace::Mcp::TokenManager.new.rotate(
          name: args[:name],
          expires_in: expires_in,
          scopes: scopes.presence,
          read_only: read_only
        )
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
