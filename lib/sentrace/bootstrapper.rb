module Sentrace
  class Bootstrapper
    DEFAULT_BASE_URL = "http://localhost:3000/sentrace"

    def initialize(io: $stdout, env: ENV)
      @io = io
      @env = env
    end

    def run(default_project_slug: nil)
      slug = non_blank(@env["SENTRACE_PROJECT_SLUG"]) || non_blank(default_project_slug)
      project_name = non_blank(@env["SENTRACE_PROJECT_NAME"])
      public_key = non_blank(@env["SENTRACE_PROJECT_PUBLIC_KEY"])
      secret_key = non_blank(@env["SENTRACE_PROJECT_SECRET_KEY"])
      generate_secret = @env["SENTRACE_GENERATE_PROJECT_SECRET"].to_s.casecmp("true").zero?
      base_url = non_blank(@env["SENTRACE_BASE_URL"]) || DEFAULT_BASE_URL

      mcp_token_raw = non_blank(@env["SENTRACE_MCP_TOKEN"])
      mcp_token_name = non_blank(@env["SENTRACE_MCP_TOKEN_NAME"])
      mcp_read_only = @env["SENTRACE_MCP_TOKEN_READ_ONLY"].to_s.casecmp("true").zero?
      mcp_scopes = non_blank(@env["SENTRACE_MCP_TOKEN_SCOPES"])
      mcp_project_ref = non_blank(@env["SENTRACE_MCP_TOKEN_PROJECT_SLUG"]) || non_blank(@env["SENTRACE_MCP_TOKEN_PROJECT_ID"])
      mcp_expires_days_raw = non_blank(@env["SENTRACE_MCP_TOKEN_EXPIRES_IN_DAYS"])
      mcp_expires_in = mcp_expires_days_raw ? Integer(mcp_expires_days_raw, 10).days : nil

      project = nil
      key = nil
      if slug
        if generate_secret && secret_key.nil? && production_stdout_secret_disallowed?
          raise ArgumentError,
            "SENTRACE_PROJECT_SECRET_KEY must be provided in production when SENTRACE_GENERATE_PROJECT_SECRET=true " \
            "(or set SENTRACE_ALLOW_GENERATED_TOKEN_STDOUT=true to explicitly print a generated secret once)"
        end

        existing_proj = Project.find_by(slug: slug.strip.downcase)
        generated_secret = (generate_secret && secret_key.nil? && existing_proj&.active_key&.secret_digest.blank?) ? SecureRandom.hex(24) : nil
        effective_secret = secret_key || generated_secret

        project, key = Project.ensure!(slug: slug, name: project_name, public_key: public_key, secret: effective_secret)
        public_dsn = Dsn.build(base_url: base_url, public_key: key.public_key, project_id: project.id)
        backend_dsn =
          if effective_secret && !suppress_secret_output?
            Dsn.build(base_url: base_url, public_key: key.public_key, secret_key: effective_secret, project_id: project.id)
          else
            public_dsn
          end
        @io.puts "Sentrace project '#{project.slug}' (id=#{project.id}) ready."
        @io.puts "SENTRACE_FRONTEND_DSN=#{public_dsn}"
        @io.puts "SENTRY_DSN=#{backend_dsn}"
        @io.puts "# Note: Explicit DSN env vars above are optional overrides for cross-origin frontends or legacy sentry-ruby."
      end

      token_record = nil
      if mcp_token_raw || mcp_token_name
        if mcp_token_raw.nil? && production_stdout_secret_disallowed?
          raise ArgumentError,
            "SENTRACE_MCP_TOKEN must be provided in production when SENTRACE_MCP_TOKEN_NAME is set " \
            "(or set SENTRACE_ALLOW_GENERATED_TOKEN_STDOUT=true to explicitly print a generated token once)"
        end

        resolved_token_name = mcp_token_name || "default"
        token_record, generated_raw = McpToken.ensure!(
          name: resolved_token_name,
          token: mcp_token_raw,
          expires_in: mcp_expires_in,
          scopes: mcp_scopes,
          read_only: mcp_read_only,
          project_id: mcp_project_ref
        )
        safe_token_name = RequestSecurity.sanitize_single_line(token_record.name, max_chars: 120)
        @io.puts "Sentrace MCP token '#{safe_token_name}' (id=#{token_record.id}, prefix=#{token_record.token_prefix}, scopes=#{token_record.scopes}) ready."
        if generated_raw && !suppress_secret_output?
          @io.puts "SENTRACE_MCP_TOKEN=#{generated_raw}"
        end
      end

      if project.nil? && token_record.nil?
        @io.puts "Sentrace bootstrap: no SENTRACE_PROJECT_SLUG or SENTRACE_MCP_TOKEN* env vars set (no-op)."
      end

      { project: project, project_key: key, mcp_token: token_record }
    end

    private
      def production_stdout_secret_disallowed?
        return false if @env["SENTRACE_ALLOW_GENERATED_TOKEN_STDOUT"].to_s.casecmp("true").zero?

        defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
      end

      def suppress_secret_output?
        @env["SENTRACE_SUPPRESS_SECRET_OUTPUT"].to_s.casecmp("true").zero?
      end

      def non_blank(val)
        str = val.to_s.strip
        str.empty? ? nil : str
      end
  end
end
