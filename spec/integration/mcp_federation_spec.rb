require "rails_helper"
require "rack/mock"
require "socket"

RSpec.describe "MCP Multi-Environment Federation Integration" do
  self.use_transactional_tests = false

  after do
    Sentrace.reset_configuration!
    Sentrace::Event.delete_all
    Sentrace::Issue.delete_all
    Sentrace::ProjectKey.delete_all
    Sentrace::Project.delete_all
    Sentrace::McpToken.delete_all
  end

  # In-memory deployment simulator wrapping real Sentrace::Mcp::Server + StreamableHTTPTransport
  # and real Sentrace::McpToken.authenticate verification so multiple isolated deployments can run
  # side-by-side in a single test process while local uses PostgreSQL LocalBackend directly.
  class SimulatedRemoteNode
    attr_reader :env_name, :token_record, :raw_token, :issues

    def initialize(env_name:, token_pair:, projects:, issues:, events:, buckets:)
      @env_name = env_name
      @token_record, @raw_token = token_pair
      @projects = projects
      @issues = issues
      @events = events
      @buckets = buckets
    end

    def call_http(uri:, headers:, body:, timeout:)
      Timeout.timeout(timeout) do
        auth = headers["Authorization"].to_s
        bearer = auth[/\ABearer\s+(\S+)\z/i, 1]
        authenticated = ActiveRecord::Base.connection_pool.with_connection do
          Sentrace::McpToken.authenticate(bearer)
        end
        unless authenticated && authenticated.id == @token_record.id
          return Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(
            status: 401,
            headers: { "www-authenticate" => 'Bearer realm="sentrace-mcp"' },
            body: '{"error":"Unauthorized"}'
          )
        end

        mcp_server = Sentrace::Mcp::Server.build(dispatcher: self)
        transport = ::MCP::Server::Transports::StreamableHTTPTransport.new(
          mcp_server,
          stateless: true,
          enable_json_response: true,
          dns_rebinding_protection: false,
          serve_subscriptions_listen: false
        )

        rack_env = Rack::MockRequest.env_for(
          uri.to_s,
          method: "POST",
          input: body,
          "CONTENT_TYPE" => headers["Content-Type"],
          "HTTP_ACCEPT" => headers["Accept"]
        )
        status, resp_headers, resp_body = transport.handle_request(Rack::Request.new(rack_env))
        chunks = []
        resp_body.each { |c| chunks << c.to_s }
        resp_body.close if resp_body.respond_to?(:close)

        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(
          status: status,
          headers: resp_headers,
          body: chunks.join
        )
      end
    end

    def list_environments
      { "environments" => [ { "name" => @env_name, "transport" => "local", "status" => "connected" } ] }
    end

    def dispatch(operation, environment: nil, **kwargs)
      case operation.to_sym
      when :list_projects
        { "environment" => @env_name, "projects" => @projects }
      when :list_issues
        filtered = @issues.dup
        filtered.select! { |i| i["status"] == kwargs[:status] } if kwargs[:status]
        { "environment" => @env_name, "issues" => filtered, "next_cursor" => nil }
      when :get_issue
        found = @issues.find { |i| i["id"] == kwargs[:issue_id].to_i }
        raise Sentrace::McpNotFoundError, "Issue #{kwargs[:issue_id]} not found" unless found

        { "environment" => @env_name, "issue" => found }
      when :update_issue_status
        found = @issues.find { |i| i["id"] == kwargs[:issue_id].to_i }
        raise Sentrace::McpNotFoundError, "Issue #{kwargs[:issue_id]} not found" unless found

        found["status"] = kwargs[:status]
        { "environment" => @env_name, "issue" => found }
      when :list_events
        { "environment" => @env_name, "events" => @events, "next_cursor" => nil }
      when :get_event
        found = @events.find { |e| e["event_id"] == kwargs[:event_id].to_s || e["id"].to_s == kwargs[:event_id].to_s }
        raise Sentrace::McpNotFoundError, "Event #{kwargs[:event_id]} not found" unless found

        { "environment" => @env_name, "event" => found }
      when :get_error_trends
        {
          "environment" => @env_name,
          "interval" => kwargs[:interval] || "hour",
          "since" => "2026-11-16T00:00:00Z",
          "until" => "2026-11-16T12:00:00Z",
          "total_events" => @buckets.sum { |b| b["count"] },
          "buckets" => @buckets
        }
      end
    end
  end

  let!(:local_project) { Sentrace::Project.provision!(slug: "checkout-api", name: "Checkout API").first }

  let(:shared_payload) do
    {
      "event_id" => "11112222333344445555666677778888",
      "timestamp" => "2026-11-16T03:00:00Z",
      "level" => "error",
      "environment" => "development",
      "release" => "v3.1.0",
      "exception" => {
        "values" => [
          {
            "type" => "Stripe::CardError",
            "value" => "Card declined for order 12345",
            "stacktrace" => {
              "frames" => [
                { "filename" => "app/services/checkout_service.rb", "function" => "charge!", "lineno" => 44, "in_app" => true }
              ]
            }
          }
        ]
      }
    }
  end

  before do
    Sentrace::Ingestion::Processor.ingest_event(
      shared_payload,
      project: local_project,
      received_at: Time.utc(2026, 11, 16, 3, 0, 5)
    )
  end

  let(:shared_fingerprint) { Sentrace::Issue.first.fingerprint }

  let(:staging_node) do
    SimulatedRemoteNode.new(
      env_name: "staging",
      token_pair: Sentrace::McpToken.issue!(name: "staging"),
      projects: [ { "id" => 10, "slug" => "checkout-api", "name" => "Checkout API", "environment" => "staging" } ],
      issues: [
        {
          "id" => 101,
          "project_id" => 10,
          "environment" => "staging",
          "fingerprint" => shared_fingerprint,
          "status" => "unresolved",
          "level" => "error",
          "exception_type" => "Stripe::CardError",
          "message" => "Card declined for order 99999",
          "first_seen_at" => "2026-11-16T01:00:00Z",
          "last_seen_at" => "2026-11-16T04:00:00Z",
          "event_count" => 7
        }
      ],
      events: [
        {
          "id" => 501,
          "event_id" => "aaaa2222333344445555666677778888",
          "project_id" => 10,
          "issue_id" => 101,
          "environment" => "staging",
          "exception_type" => "Stripe::CardError",
          "message" => "Card declined for order 99999",
          "occurred_at" => "2026-11-16T04:00:00Z"
        }
      ],
      buckets: [ { "bucket_start" => "2026-11-16T04:00:00Z", "count" => 7 } ]
    )
  end

  let(:production_node) do
    SimulatedRemoteNode.new(
      env_name: "production",
      token_pair: Sentrace::McpToken.issue!(name: "production"),
      projects: [ { "id" => 20, "slug" => "checkout-api", "name" => "Checkout API", "environment" => "production" } ],
      issues: [
        {
          "id" => 202,
          "project_id" => 20,
          "environment" => "production",
          "fingerprint" => shared_fingerprint,
          "status" => "unresolved",
          "level" => "error",
          "exception_type" => "Stripe::CardError",
          "message" => "Card declined for order 88888",
          "first_seen_at" => "2026-11-16T02:00:00Z",
          "last_seen_at" => "2026-11-16T05:00:00Z",
          "event_count" => 42
        },
        {
          "id" => 203,
          "project_id" => 20,
          "environment" => "production",
          "fingerprint" => "f" * 64,
          "status" => "unresolved",
          "level" => "fatal",
          "exception_type" => "Redis::CannotConnectError",
          "message" => "Error connecting to Redis",
          "first_seen_at" => "2026-11-16T05:30:00Z",
          "last_seen_at" => "2026-11-16T05:30:00Z",
          "event_count" => 3
        }
      ],
      events: [
        {
          "id" => 601,
          "event_id" => "bbbb2222333344445555666677778888",
          "project_id" => 20,
          "issue_id" => 202,
          "environment" => "production",
          "exception_type" => "Stripe::CardError",
          "message" => "Card declined for order 88888",
          "occurred_at" => "2026-11-16T05:00:00Z"
        }
      ],
      buckets: [ { "bucket_start" => "2026-11-16T05:00:00Z", "count" => 45 } ]
    )
  end

  it "federates concurrently across local, staging, and production, correlating matching fingerprints and round-tripping targeted mutations" do
    config = Sentrace::Configuration.new.tap do |c|
      c.environments = {
        local: { transport: :local },
        staging: {
          transport: :http,
          url: "https://staging.example.com/sentrace/mcp",
          token: staging_node.raw_token,
          timeout: 2.0
        },
        production: {
          transport: :http,
          url: "https://errors.example.com/sentrace/mcp",
          token: production_node.raw_token,
          timeout: 2.0
        }
      }
    end

    nodes_by_host = {
      "staging.example.com" => staging_node,
      "errors.example.com" => production_node
    }
    remote_client = Sentrace::Mcp::RemoteHttpClient.new(
      http_requester: ->(uri:, headers:, body:, timeout:) {
        nodes_by_host.fetch(uri.host).call_http(uri: uri, headers: headers, body: body, timeout: timeout)
      }
    )
    dispatcher = Sentrace::Mcp::Dispatcher.new(config: config, remote_client: remote_client)

    envs = dispatcher.list_environments
    expect(envs["environments"].map { |e| [ e["name"], e["status"] ] }).to eq(
      [ [ "local", "connected" ], [ "staging", "connected" ], [ "production", "connected" ] ]
    )

    merged_issues = dispatcher.dispatch(:list_issues, environment: "all")
    expect(merged_issues["environments_queried"]).to eq(%w[local staging production])
    expect(merged_issues["errors"]).to eq([])
    expect(merged_issues["issues"].size).to eq(4)
    expect(merged_issues["issues"].first["environment"]).to eq("production")
    expect(merged_issues["issues"].first["exception_type"]).to eq("Redis::CannotConnectError")

    expect(merged_issues["fingerprint_correlations"].size).to eq(1)
    corr = merged_issues["fingerprint_correlations"].first
    expect(corr["fingerprint"]).to eq(shared_fingerprint)
    expect(corr["environments"]).to contain_exactly("local", "staging", "production")
    expect(corr["total_event_count"]).to eq(1 + 7 + 42)

    merged_trends = dispatcher.dispatch(
      :get_error_trends,
      environment: "all",
      interval: "hour",
      since: "2026-11-16T00:00:00Z",
      until: "2026-11-16T12:00:00Z"
    )
    expect(merged_trends["total_events"]).to eq(1 + 7 + 45)
    expect(merged_trends["series"].map { |s| s["environment"] }).to eq(%w[local staging production])

    merged_events = dispatcher.dispatch(:list_events, environment: "all")
    expect(merged_events["events"].map { |e| e["environment"] }).to eq(%w[production staging local])

    # Round-trip targeted status mutation on staging only
    updated = dispatcher.dispatch(:update_issue_status, environment: "staging", issue_id: 101, status: "resolved")
    expect(updated.dig("issue", "status")).to eq("resolved")
    expect(Sentrace::Issue.first.reload.status).to eq("unresolved")
    expect(production_node.issues.first["status"]).to eq("unresolved")

    # Rotating staging token isolates staging as authentication_failed while local + production succeed
    Sentrace::McpToken.rotate!(name: "staging")
    after_rotate = dispatcher.dispatch(:list_issues, environment: "all")
    expect(after_rotate["issues"].map { |i| i["environment"] }.uniq).to contain_exactly("local", "production")
    expect(after_rotate["errors"]).to contain_exactly(
      hash_including("environment" => "staging", "category" => "authentication_failed")
    )
    expect(JSON.generate(after_rotate)).not_to include(staging_node.raw_token)
  end

  it "enforces real Net::HTTP socket read timeouts per environment without blocking healthy environments" do
    hanging_server = TCPServer.new("127.0.0.1", 0)
    hanging_port = hanging_server.addr[1]
    accept_thread = Thread.new do
      client_sock = hanging_server.accept
      sleep 0.6
      client_sock&.close
    rescue IOError, Errno::EBADF
      nil
    end

    begin
      config = Sentrace::Configuration.new.tap do |c|
        c.environments = {
          local: { transport: :local },
          staging: {
            transport: :http,
            url: "http://127.0.0.1:#{hanging_port}/sentrace/mcp",
            token: staging_node.raw_token,
            timeout: 0.1
          },
          production: {
            transport: :http,
            url: "https://errors.example.com/sentrace/mcp",
            token: production_node.raw_token,
            timeout: 2.0
          }
        }
      end

      default_client = Sentrace::Mcp::RemoteHttpClient.new
      hybrid_client = Sentrace::Mcp::RemoteHttpClient.new(
        http_requester: lambda do |uri:, headers:, body:, timeout:|
          if uri.host == "127.0.0.1"
            default_client.send(:perform_net_http_post, uri: uri, headers: headers, body: body, timeout: timeout)
          else
            production_node.call_http(uri: uri, headers: headers, body: body, timeout: timeout)
          end
        end
      )
      dispatcher = Sentrace::Mcp::Dispatcher.new(config: config, remote_client: hybrid_client)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = dispatcher.dispatch(:list_issues, environment: "all")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 0.5
      expect(result["issues"].map { |i| i["environment"] }).to contain_exactly("local", "production", "production")
      expect(result["errors"]).to contain_exactly(
        hash_including(
          "environment" => "staging",
          "category" => "timeout"
        )
      )
      serialized = JSON.generate(result)
      expect(serialized).not_to include(staging_node.raw_token)
      expect(serialized).not_to include(production_node.raw_token)
    ensure
      hanging_server.close unless hanging_server.closed?
      accept_thread.join(0.2)
    end
  end

  it "executes a full Rack round-trip from RemoteHttpClient through Rails.application /sentrace/mcp controller" do
    _token_rec, raw_tok = Sentrace::McpToken.issue!(name: "rack-e2e")
    mock_rack = Rack::MockRequest.new(Rails.application)

    rack_client = Sentrace::Mcp::RemoteHttpClient.new(
      http_requester: lambda do |uri:, headers:, body:, timeout:|
        _ = timeout
        rack_res = mock_rack.post(
          uri.to_s,
          input: body,
          "CONTENT_TYPE" => headers["Content-Type"],
          "HTTP_ACCEPT" => headers["Accept"],
          "HTTP_AUTHORIZATION" => headers["Authorization"],
          "HTTPS" => uri.scheme == "https" ? "on" : "off"
        )
        Sentrace::Mcp::RemoteHttpClient::HttpResponse.new(
          status: rack_res.status,
          headers: rack_res.headers,
          body: rack_res.body
        )
      end
    )

    config = Sentrace::Configuration.new.tap do |c|
      c.environments = {
        remote_prod: {
          transport: :http,
          url: "https://errors.example.com/sentrace/mcp",
          token: raw_tok,
          timeout: 2.0
        }
      }
    end
    dispatcher = Sentrace::Mcp::Dispatcher.new(config: config, remote_client: rack_client)

    issues_res = dispatcher.dispatch(:list_issues, environment: "remote_prod")
    expect(issues_res["environment"]).to eq("remote_prod")
    expect(issues_res["issues"].size).to eq(1)
    expect(issues_res["issues"].first["fingerprint"]).to eq(shared_fingerprint)
    expect(issues_res["issues"].first["environment"]).to eq("remote_prod")
  end

  it "probes multiple offline remote environments concurrently in list_environments within remote_ping_timeout and marks blank environments unconfigured" do
    config = Sentrace::Configuration.new.tap do |c|
      c.remote_timeout = 5.0
      c.remote_ping_timeout = 0.2
      c.environments = {
        local: { transport: :local },
        staging: { transport: :http, url: "https://staging.internal.example/sentrace/mcp", token: "snt_mcp_stg", timeout: 5.0 },
        pre_prod: { transport: :http, url: "https://preprod.internal.example/sentrace/mcp", token: "snt_mcp_pre", timeout: 5.0 },
        production: { transport: :http, url: "https://prod.internal.example/sentrace/mcp", token: "snt_mcp_prd", timeout: 5.0 },
        dr_standby: { transport: :http, url: nil, token: nil, timeout: 5.0 }
      }
    end

    slow_dns_client = Sentrace::Mcp::RemoteHttpClient.new(
      http_requester: lambda do |uri:, headers:, body:, timeout:|
        _ = [ uri, headers, body, timeout ]
        sleep 2.0
        raise "unreachable"
      end
    )
    dispatcher = Sentrace::Mcp::Dispatcher.new(config: config, remote_client: slow_dns_client)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = dispatcher.list_environments
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(elapsed).to be < 0.55
    expect(result["environments"].map { |e| [ e["name"], e["status"] ] }).to eq(
      [
        [ "local", "connected" ],
        [ "staging", "timeout" ],
        [ "pre_prod", "timeout" ],
        [ "production", "timeout" ],
        [ "dr_standby", "unconfigured" ]
      ]
    )

    federated = dispatcher.dispatch(:list_projects, environment: "all")
    expect(federated["errors"]).to include(
      hash_including("environment" => "dr_standby", "category" => "unconfigured")
    )
  end
end
