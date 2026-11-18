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
      base_url = non_blank(@env["SENTRACE_BASE_URL"]) || DEFAULT_BASE_URL

      mcp_token_raw = non_blank(@env["SENTRACE_MCP_TOKEN"])
      mcp_token_name = non_blank(@env["SENTRACE_MCP_TOKEN_NAME"])

      project = nil
      key = nil
      if slug
        project, key = Project.ensure!(slug: slug, name: project_name, public_key: public_key)
        dsn = Dsn.build(base_url: base_url, public_key: key.public_key, project_id: project.id)
        @io.puts "Sentrace project '#{project.slug}' (id=#{project.id}) ready."
        @io.puts "SENTRACE_FRONTEND_DSN=#{dsn}"
        @io.puts "SENTRY_DSN=#{dsn}"
        @io.puts "# Note: Explicit DSN env vars above are optional overrides for cross-origin frontends or legacy sentry-ruby."
      end

      token_record = nil
      if mcp_token_raw || mcp_token_name
        resolved_token_name = mcp_token_name || "default"
        token_record, generated_raw = McpToken.ensure!(name: resolved_token_name, token: mcp_token_raw)
        @io.puts "Sentrace MCP token '#{token_record.name}' (id=#{token_record.id}, prefix=#{token_record.token_prefix}) ready."
        if generated_raw
          @io.puts "SENTRACE_MCP_TOKEN=#{generated_raw}"
        end
      end

      if project.nil? && token_record.nil?
        @io.puts "Sentrace bootstrap: no SENTRACE_PROJECT_SLUG or SENTRACE_MCP_TOKEN* env vars set (no-op)."
      end

      { project: project, project_key: key, mcp_token: token_record }
    end

    private
      def non_blank(val)
        str = val.to_s.strip
        str.empty? ? nil : str
      end
  end
end
