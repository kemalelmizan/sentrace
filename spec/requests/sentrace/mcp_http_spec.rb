require "rails_helper"

RSpec.describe "Sentrace Remote Streamable HTTP MCP Endpoint (/sentrace/mcp)", type: :request do
  after { Sentrace.reset_configuration! }

  let!(:project_pair) { Sentrace::Project.provision!(slug: "billing-service", name: "Billing Service") }
  let(:project) { project_pair.first }
  let(:dsn_key) { project_pair.last }
  let!(:mcp_token_pair) { Sentrace::McpToken.issue!(name: "staging-node") }
  let(:mcp_token_record) { mcp_token_pair.first }
  let(:raw_mcp_token) { mcp_token_pair.last }

  let(:mcp_headers) do
    {
      "Authorization" => "Bearer #{raw_mcp_token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
  end

  def json_rpc(method, params = {}, id: 1)
    JSON.generate(
      jsonrpc: "2.0",
      id: id,
      method: method,
      params: params
    )
  end

  describe "transport security and bearer authentication" do
    it "rejects plain HTTP requests on non-loopback hosts with 403 Forbidden" do
      post "http://staging.example.com/sentrace/mcp",
        params: json_rpc("tools/list"),
        headers: mcp_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(JSON.parse(response.body)["error"]).to include("HTTPS is required")
    end

    it "allows plain HTTP requests on loopback hosts for local testing" do
      post "http://127.0.0.1/sentrace/mcp",
        params: json_rpc("tools/list"),
        headers: mcp_headers

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      body = JSON.parse(response.body)
      expect(body.dig("result", "tools").map { |t| t["name"] }).to include("list_issues")
    end

    it "rejects missing, invalid, revoked, and ingestion DSN credentials with 401 Unauthorized" do
      base_headers = { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }

      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc("tools/list"),
        headers: base_headers
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["WWW-Authenticate"]).to include("Bearer")

      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc("tools/list"),
        headers: base_headers.merge("Authorization" => "Bearer #{dsn_key.public_key}")
      expect(response).to have_http_status(:unauthorized)

      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc("tools/list"),
        headers: base_headers.merge("Authorization" => "Sentry sentry_key=#{dsn_key.public_key}")
      expect(response).to have_http_status(:unauthorized)

      mcp_token_record.revoke!
      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc("tools/list"),
        headers: mcp_headers
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "stateless Streamable HTTP MCP execution and deployment_environment scoping" do
    before do
      Sentrace.configure do |config|
        config.deployment_environment = "staging-eu"
        config.environments = {
          local: { transport: :local },
          production: { transport: :http, url: "https://prod.example.com/sentrace/mcp", token: "unused-tok" }
        }
      end

      Sentrace::Ingestion::Processor.ingest_event(
        {
          "event_id" => "aaaa1111bbbb2222cccc3333dddd4444",
          "timestamp" => "2026-11-16T04:00:00Z",
          "level" => "error",
          "environment" => "staging",
          "release" => "v2.4.0",
          "exception" => {
            "values" => [
              {
                "type" => "Stripe::CardError",
                "value" => "Card declined",
                "stacktrace" => {
                  "frames" => [
                    { "filename" => "app/services/charge_service.rb", "function" => "call", "lineno" => 27, "in_app" => true }
                  ]
                }
              }
            ]
          }
        },
        project: project
      )
    end

    it "serves initialize, tools/call, resources/read, and prompts/get stamped with deployment_environment" do
      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc(
          "initialize",
          {
            protocolVersion: "2025-11-25",
            capabilities: {},
            clientInfo: { name: "sentrace-federation-spec", version: "1.0" }
          },
          id: 1
        ),
        headers: mcp_headers

      expect(response).to have_http_status(:ok)
      init_body = JSON.parse(response.body)
      expect(init_body.dig("result", "serverInfo", "name")).to eq("sentrace")

      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc(
          "tools/call",
          { name: "list_issues", arguments: { project_id: "billing-service" } },
          id: 2
        ),
        headers: mcp_headers

      expect(response).to have_http_status(:ok)
      call_body = JSON.parse(response.body)
      structured = call_body.dig("result", "structuredContent")
      expect(structured["issues"].size).to eq(1)
      issue_hash = structured["issues"].first
      expect(issue_hash["environment"]).to eq("staging-eu")
      expect(issue_hash["exception_type"]).to eq("Stripe::CardError")

      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc(
          "resources/read",
          { uri: "sentrace://issues/#{issue_hash["id"]}" },
          id: 3
        ),
        headers: mcp_headers

      expect(response).to have_http_status(:ok)
      res_body = JSON.parse(response.body)
      res_payload = JSON.parse(res_body.dig("result", "contents", 0, "text"))
      expect(res_payload["environment"]).to eq("staging-eu")
      expect(res_payload.dig("issue", "id")).to eq(issue_hash["id"])

      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc(
          "prompts/get",
          { name: "investigate_issue", arguments: { issue_id: issue_hash["id"].to_s } },
          id: 4
        ),
        headers: mcp_headers

      expect(response).to have_http_status(:ok)
      prompt_body = JSON.parse(response.body)
      prompt_text = prompt_body.dig("result", "messages", 0, "content", "text")
      expect(prompt_text).to include("Observed Evidence")
      expect(prompt_text).to include("Stripe::CardError")
    end

    it "scopes remote HTTP nodes strictly to their own database and never recurses to :http peers" do
      post "https://staging.example.com/sentrace/mcp",
        params: json_rpc(
          "tools/call",
          { name: "list_environments", arguments: {} },
          id: 10
        ),
        headers: mcp_headers

      expect(response).to have_http_status(:ok)
      envs = JSON.parse(response.body).dig("result", "structuredContent", "environments")
      expect(envs.map { |e| e["name"] }).to eq([ "staging-eu" ])
      expect(envs.first["transport"]).to eq("local")
    end

    it "returns 405 Method Not Allowed on authenticated GET requests in stateless mode" do
      get "https://staging.example.com/sentrace/mcp", headers: mcp_headers
      expect(response).to have_http_status(:method_not_allowed)
    end
  end
end
