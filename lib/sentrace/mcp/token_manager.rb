module Sentrace
  module Mcp
    class TokenManager
      class TokenNotFoundError < Error; end

      def initialize(io: $stdout)
        @io = io
      end

      def list
        tokens = McpToken.order(:id).to_a
        if tokens.empty?
          @io.puts "No Sentrace MCP tokens issued."
          return tokens
        end

        @io.puts format("%-6s %-24s %-16s %-10s %-12s %-22s %s", "ID", "NAME", "PREFIX", "STATUS", "SCOPES", "EXPIRES AT", "LAST USED AT")
        tokens.each do |token|
          status =
            if !token.active || token.revoked_at.present?
              "revoked"
            elsif token.expired?
              "expired"
            else
              "active"
            end
          expires_at = token.expires_at&.utc&.iso8601 || "(never)"
          last_used = token.last_used_at&.utc&.iso8601 || "(never)"
          @io.puts format("%-6s %-24s %-16s %-10s %-12s %-22s %s", token.id, token.name, token.token_prefix, status, token.scopes, expires_at, last_used)
        end
        tokens
      end

      def create(name: nil, expires_at: nil, expires_in: nil, scopes: nil, read_only: false)
        resolved_name = normalize_name_or_default(name)
        record, raw_token = McpToken.issue!(
          name: resolved_name,
          expires_at: expires_at,
          expires_in: expires_in,
          scopes: scopes,
          read_only: read_only
        )

        @io.puts "Created Sentrace MCP token (store securely; plaintext is shown only once):"
        @io.puts "  ID:      #{record.id}"
        @io.puts "  Name:    #{record.name}"
        @io.puts "  Prefix:  #{record.token_prefix}"
        @io.puts "  Scopes:  #{record.scopes}"
        @io.puts "  Expires: #{record.expires_at&.utc&.iso8601 || '(never)'}"
        @io.puts "  Token:   #{raw_token}"
        [ record, raw_token ]
      end

      def rotate(name: nil, expires_at: nil, expires_in: nil, scopes: nil, read_only: false)
        resolved_name = normalize_name_or_default(name)
        record, raw_token = McpToken.rotate!(
          name: resolved_name,
          expires_at: expires_at,
          expires_in: expires_in,
          scopes: scopes,
          read_only: read_only
        )

        @io.puts "Rotated Sentrace MCP token for '#{record.name}' (store securely; plaintext is shown only once):"
        @io.puts "  ID:      #{record.id}"
        @io.puts "  Name:    #{record.name}"
        @io.puts "  Prefix:  #{record.token_prefix}"
        @io.puts "  Scopes:  #{record.scopes}"
        @io.puts "  Expires: #{record.expires_at&.utc&.iso8601 || '(never)'}"
        @io.puts "  Token:   #{raw_token}"
        [ record, raw_token ]
      end

      def revoke(id:)
        raw_id = id.to_s.strip
        if raw_id.empty?
          raise ArgumentError, "Token ID is required (usage: bin/rails \"sentrace:mcp:tokens:revoke[1]\")"
        end

        token = McpToken.find_by(id: raw_id)
        unless token
          raise TokenNotFoundError, "Sentrace MCP token ##{raw_id} not found."
        end

        token.revoke!
        @io.puts "Revoked Sentrace MCP token ##{token.id} (#{token.name}, prefix=#{token.token_prefix})."
        token
      end

      private
        def normalize_name_or_default(name)
          trimmed = name.to_s.strip
          trimmed.empty? ? "default" : trimmed
        end
    end
  end
end
