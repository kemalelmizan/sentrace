require "rails_helper"

RSpec.describe Sentrace::Mcp::RemoteHttpClient do
  def build_env(name: :staging, url: "https://staging.example.com/sentrace/mcp", token: "snt_mcp_secret_tok_999", timeout: 2.0)
    Sentrace::Configuration::EnvironmentDefinition.new(
      name: name,
      transport: :http,
      url: url,
      token: token,
      timeout: timeout
    )
  end

  it "enforces HTTPS for non-loopback URLs while allowing loopback HTTP" do
    insecure_env = build_env(url: "http://staging.example.com/sentrace/mcp")
    client = described_class.new(http_requester: ->(**_args) { raise "should not execute" })

    expect {
      client.call_environment(insecure_env, :list_projects)
    }.to raise_error(Sentrace::McpRemoteError) { |err|
      expect(err.environment).to eq("staging")
      expect(err.category).to eq("insecure_transport")
      expect(err.message).not_to include("snt_mcp_secret_tok_999")
    }

    loopback_env = build_env(url: "http://127.0.0.1:3005/sentrace/mcp")
    ok_client = described_class.new(
      http_requester: lambda do |uri:, headers:, body:, timeout:|
        expect(uri.host).to eq("127.0.0.1")
        expect(headers["Authorization"]).to eq("Bearer snt_mcp_secret_tok_999")
        expect(timeout).to eq(2.0)
        parsed_req = JSON.parse(body)
        expect(parsed_req["method"]).to eq("tools/call")
        expect(parsed_req.dig("params", "name")).to eq("list_projects")

        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            jsonrpc: "2.0",
            id: parsed_req["id"],
            result: {
              structuredContent: {
                "environment" => "staging-eu",
                "projects" => [ { "id" => 1, "slug" => "api", "environment" => "staging-eu" } ]
              },
              isError: false
            }
          )
        )
      end
    )

    res = ok_client.call_environment(loopback_env, :list_projects)
    expect(res["environment"]).to eq("staging")
    expect(res["remote_deployment_environment"]).to eq("staging-eu")
    expect(res["projects"].first["environment"]).to eq("staging")
  end

  it "maps HTTP 401/403, timeouts, socket failures, malformed JSON, and remote tool errors without leaking tokens" do
    env = build_env(token: "snt_mcp_ultra_sensitive_value")

    auth_client = described_class.new(
      http_requester: ->(**_args) {
        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(status: 401, headers: {}, body: '{"error":"Unauthorized"}')
      }
    )
    expect {
      auth_client.call_environment(env, :list_issues)
    }.to raise_error(Sentrace::McpRemoteError) { |e|
      expect(e.category).to eq("authentication_failed")
      expect(e.message).not_to include("snt_mcp_ultra_sensitive_value")
    }

    timeout_client = described_class.new(http_requester: ->(**_args) { raise Net::ReadTimeout, "execution expired" })
    expect {
      timeout_client.call_environment(env, :list_issues)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("timeout") }

    down_client = described_class.new(http_requester: ->(**_args) { raise Errno::ECONNREFUSED })
    expect {
      down_client.call_environment(env, :list_issues)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("unreachable") }

    bad_json_client = described_class.new(
      http_requester: ->(**_args) {
        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(status: 200, headers: {}, body: "<html>502</html>")
      }
    )
    expect {
      bad_json_client.call_environment(env, :list_issues)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("protocol_error") }

    not_found_client = described_class.new(
      http_requester: ->(**_args) {
        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(
          status: 200,
          headers: {},
          body: JSON.generate(
            jsonrpc: "2.0",
            id: "1",
            result: {
              isError: true,
              structuredContent: {
                "error" => "Issue 999 not found (tok=snt_mcp_ultra_sensitive_value)",
                "category" => "not_found"
              }
            }
          )
        )
      }
    )
    expect {
      not_found_client.call_environment(env, :get_issue, issue_id: 999)
    }.to raise_error(Sentrace::McpNotFoundError) { |e|
      expect(e.message).to include("[REDACTED]")
      expect(e.message).not_to include("snt_mcp_ultra_sensitive_value")
    }
  end

  it "checks environment_status via JSON-RPC ping" do
    env = build_env

    ok_client = described_class.new(
      http_requester: ->(**_args) {
        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(
          status: 200,
          headers: {},
          body: '{"jsonrpc":"2.0","id":"ping","result":{}}'
        )
      }
    )
    expect(ok_client.environment_status(env)).to eq("connected")

    unauth_client = described_class.new(
      http_requester: ->(**_args) {
        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(status: 401, headers: {}, body: "{}")
      }
    )
    expect(unauth_client.environment_status(env)).to eq("authentication_failed")
  end
end
