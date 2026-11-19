require "rails_helper"
require "net/http"

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

  it "reports unconfigured without performing network I/O when url or token is blank" do
    network_called = false
    client = described_class.new(http_requester: ->(**_args) { network_called = true })

    blank_url_env = build_env(url: nil, token: "snt_mcp_secret")
    blank_token_env = build_env(url: "https://staging.example.com/sentrace/mcp", token: "")

    expect(client.environment_status(blank_url_env)).to eq("unconfigured")
    expect(client.environment_status(blank_token_env)).to eq("unconfigured")

    expect {
      client.call_environment(blank_url_env, :list_issues)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("unconfigured") }

    expect {
      client.call_environment(blank_token_env, :list_issues)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("unconfigured") }

    expect(network_called).to be(false)
  end

  it "enforces strict monotonic wall-clock and SSL handshake timeouts in perform_net_http_post" do
    stalled_tls_server = TCPServer.new("127.0.0.1", 0)
    port = stalled_tls_server.addr[1]
    accept_thread = Thread.new do
      sock = stalled_tls_server.accept
      sleep 1.0
      sock&.close
    rescue IOError, Errno::EBADF
      nil
    end

    begin
      tls_env = build_env(url: "https://localhost:#{port}/sentrace/mcp", timeout: 5.0)
      real_client = described_class.new

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = real_client.environment_status(tls_env, timeout: 0.15)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(status).to eq("timeout")
      expect(elapsed).to be < 0.5
    ensure
      stalled_tls_server.close unless stalled_tls_server.closed?
      accept_thread.join(0.2)
    end
  end

  it "rejects embedded URL userinfo, control-character tokens, and oversized or deeply nested remote JSON responses" do
    no_io_client = described_class.new(http_requester: ->(**_args) { raise "must not call network" })

    userinfo_env = build_env(url: "https://admin:secret@staging.example.com/sentrace/mcp")
    expect {
      no_io_client.call_environment(userinfo_env, :list_projects)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("invalid_endpoint") }

    crlf_tok_env = build_env(token: "snt_mcp_bad\r\nHeader: injected")
    expect {
      no_io_client.call_environment(crlf_tok_env, :list_projects)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("invalid_endpoint") }

    env = build_env
    oversized_client = described_class.new(
      http_requester: ->(**_args) {
        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(
          status: 200,
          headers: {},
          body: "x" * (described_class::MAX_REMOTE_RESPONSE_BYTES + 10)
        )
      }
    )
    expect {
      oversized_client.call_environment(env, :list_projects)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("protocol_error") }

    deep_json = ("{\"a\":" * 70) + "1" + ("}" * 70)
    deep_client = described_class.new(
      http_requester: ->(**_args) {
        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(status: 200, headers: {}, body: deep_json)
      }
    )
    expect {
      deep_client.call_environment(env, :list_projects)
    }.to raise_error(Sentrace::McpRemoteError) { |e| expect(e.category).to eq("protocol_error") }
  end
end
