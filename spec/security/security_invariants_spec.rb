require "rails_helper"
require "zlib"

RSpec.describe "Sentrace Security Invariants (SPEC.md §13)", type: :request do
  after { Sentrace.reset_configuration! }

  let!(:project_pair) { Sentrace::Project.provision!(slug: "secure-app") }
  let(:project) { project_pair.first }
  let(:dsn_key) { project_pair.last }
  let!(:mcp_pair) { Sentrace::McpToken.issue!(name: "sec-audit") }
  let(:mcp_raw_token) { mcp_pair.last }

  it "enforces body size limits before JSON parsing on ingestion" do
    Sentrace.configure { |c| c.max_envelope_size = 256 }
    expect(Sentrace::Ingestion::EnvelopeParser).not_to receive(:parse)

    post "/sentrace/api/#{project.id}/envelope",
      params: "x" * 1024,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "Sentry sentry_key=#{dsn_key.public_key}"
      }

    expect(response).to have_http_status(413)
  end

  it "validates ingestion credentials before full envelope processing" do
    expect(Sentrace::Ingestion::Processor).not_to receive(:process_raw_envelope)

    envelope = <<~ENV
      {"event_id":"11112222333344445555666677778888"}
      {"type":"event"}
      {"message":"unauthenticated"}
    ENV

    post "/sentrace/api/#{project.id}/envelope",
      params: envelope,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "Sentry sentry_key=invalid_public_key"
      }

    expect(response).to have_http_status(:unauthorized)
  end

  it "never logs raw envelope secrets when an internal error occurs during ingestion" do
    log_io = StringIO.new
    test_logger = ActiveSupport::Logger.new(log_io)
    allow(Rails).to receive(:logger).and_return(test_logger)
    allow(Sentrace::Ingestion::Processor).to receive(:process_raw_envelope).and_raise(RuntimeError, "db boom")

    secret_marker = "TOP_SECRET_PAYLOAD_MARKER_998877"
    envelope = "{\"event_id\":\"11112222333344445555666677778888\"}\n{\"type\":\"event\"}\n{\"message\":\"#{secret_marker}\"}\n"

    post "/sentrace/api/#{project.id}/envelope",
      params: envelope,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "Sentry sentry_key=#{dsn_key.public_key}"
      }

    expect(response).to have_http_status(:internal_server_error)
    expect(response.body).not_to include(secret_marker)
    expect(response.body).not_to include("db boom")
    expect(log_io.string).not_to include(secret_marker)
  end

  it "prevents SQL injection and enforces MAX_LIMIT (100) across MCP and internal list operations" do
    105.times do |idx|
      Sentrace::Ingestion::Processor.ingest_event(
        {
          "event_id" => format("%032x", idx + 5000),
          "timestamp" => Time.current.utc.iso8601,
          "level" => "error",
          "message" => "Pagination cap check #{idx}"
        },
        project: project
      )
    end

    backend = Sentrace::Mcp::LocalBackend.new(environment_name: "local")

    expect {
      backend.list_events(project_id: project.id, limit: 10_000)
    }.to raise_error(Sentrace::McpInvalidParamsError, /limit must be between 1 and 100/)

    capped = backend.list_events(project_id: project.id, limit: Sentrace::Mcp::LocalBackend::MAX_LIMIT)
    expect(capped["events"].size).to eq(Sentrace::Mcp::LocalBackend::MAX_LIMIT)
    expect(capped["next_cursor"]).to be_present

    # SQL injection attempts in project slug, release filter, and trend interval
    expect {
      backend.list_issues(project_id: "secure-app' OR 1=1--")
    }.to raise_error(Sentrace::McpNotFoundError)

    sqli_release = backend.list_issues(project_id: project.id, release: "' OR 1=1--")
    expect(sqli_release["issues"]).to eq([])

    expect {
      backend.get_error_trends(project_id: project.id, interval: "hour; DROP TABLE sentrace_events;--")
    }.to raise_error(Sentrace::McpInvalidParamsError)

    expect(Sentrace::Event.count).to eq(105)
  end

  it "emits strict defensive HTTP security headers across ingestion, MCP, and internal endpoints" do
    expected_headers = {
      "Cache-Control" => "no-store",
      "X-Content-Type-Options" => "nosniff",
      "X-Frame-Options" => "DENY",
      "Content-Security-Policy" => "default-src 'none'; frame-ancestors 'none'",
      "Referrer-Policy" => "no-referrer"
    }

    envelope = "{\"event_id\":\"11112222333344445555666677778888\"}\n{\"type\":\"event\"}\n{\"message\":\"hdr check\"}\n"
    post "/sentrace/api/#{project.id}/envelope",
      params: envelope,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "Sentry sentry_key=#{dsn_key.public_key}"
      }
    expect(response).to have_http_status(:ok)
    expected_headers.each { |k, v| expect(response.headers[k]).to eq(v) }

    post "https://staging.example.com/sentrace/mcp",
      params: JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list", params: {}),
      headers: {
        "Authorization" => "Bearer #{mcp_raw_token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream"
      }
    expect(response).to have_http_status(:ok)
    expected_headers.each { |k, v| expect(response.headers[k]).to eq(v) }

    get "/sentrace/internal/projects"
    expect(response).to have_http_status(:unauthorized)
    expected_headers.each { |k, v| expect(response.headers[k]).to eq(v) }
  end

  it "rejects spoofed loopback Host headers from external IPs and cross-origin browser requests on /sentrace/mcp" do
    rpc_body = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list", params: {})
    base_mcp_headers = {
      "Authorization" => "Bearer #{mcp_raw_token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }

    post "http://localhost/sentrace/mcp",
      params: rpc_body,
      headers: base_mcp_headers.merge("REMOTE_ADDR" => "203.0.113.10")
    expect(response).to have_http_status(:forbidden)

    post "http://127.0.0.1/sentrace/mcp",
      params: rpc_body,
      headers: base_mcp_headers.merge("REMOTE_ADDR" => "203.0.113.10")
    expect(response).to have_http_status(:forbidden)

    post "https://staging.example.com/sentrace/mcp",
      params: rpc_body,
      headers: base_mcp_headers.merge("Origin" => "https://evil.example.com")
    expect(response).to have_http_status(:forbidden)

    post "https://staging.example.com/sentrace/mcp",
      params: rpc_body,
      headers: base_mcp_headers.merge("Origin" => "null")
    expect(response).to have_http_status(:forbidden)

    post "https://staging.example.com/sentrace/mcp",
      params: rpc_body,
      headers: base_mcp_headers.merge("Sec-Fetch-Site" => "cross-site")
    expect(response).to have_http_status(:forbidden)
  end

  it "enforces CSRF, Origin, parameter scalar validation, and stats range bounds on /sentrace/internal/*" do
    Sentrace.configure do |config|
      config.internal_authenticator = ->(req) {
        req.headers["Cookie"].to_s.include?("admin_session=valid") ||
          req.headers["Authorization"] == "Bearer #{mcp_raw_token}"
      }
    end

    # Cross-origin browser request is blocked even with valid Cookie or Bearer auth
    get "https://app.example.com/sentrace/internal/projects",
      headers: {
        "Authorization" => "Bearer #{mcp_raw_token}",
        "Origin" => "https://evil.example.com"
      }
    expect(response).to have_http_status(:forbidden)

    # Cookie-authenticated form POST without Origin / JSON / X-CSRF-Token is blocked as CSRF
    post "https://app.example.com/sentrace/internal/projects",
      params: { slug: "csrf-blocked" },
      headers: { "Cookie" => "admin_session=valid" }
    expect(response).to have_http_status(:forbidden)
    expect(Sentrace::Project.find_by(slug: "csrf-blocked")).to be_nil

    # Cookie-authenticated JSON POST succeeds
    post "https://app.example.com/sentrace/internal/projects",
      params: JSON.generate(slug: "cookie-json-ok"),
      headers: {
        "Cookie" => "admin_session=valid",
        "Content-Type" => "application/json"
      }
    expect(response).to have_http_status(:created)

    # Cookie-authenticated POST with verified same-origin Origin succeeds
    post "https://app.example.com/sentrace/internal/projects",
      params: { slug: "cookie-origin-ok" },
      headers: {
        "Cookie" => "admin_session=valid",
        "Origin" => "https://app.example.com"
      }
    expect(response).to have_http_status(:created)

    # Cookie-authenticated POST with X-CSRF-Token succeeds
    post "https://app.example.com/sentrace/internal/projects",
      params: { slug: "cookie-csrf-token-ok" },
      headers: {
        "Cookie" => "admin_session=valid",
        "X-CSRF-Token" => "host-verified-token"
      }
    expect(response).to have_http_status(:created)

    # Nested Hash/Array parameters return 422 instead of 500 ForbiddenAttributesError / TypeError
    auth_hdr = { "Authorization" => "Bearer #{mcp_raw_token}" }
    patch "/sentrace/internal/projects/#{project.id}",
      params: { name: { nested: "bad" } },
      headers: auth_hdr
    expect(response).to have_http_status(422)

    get "/sentrace/internal/issues",
      params: { status: [ "unresolved" ] },
      headers: auth_hdr
    expect(response).to have_http_status(422)

    # Out-of-range stats days return 422 instead of 500 RangeError / OOM
    get "/sentrace/internal/stats",
      params: { days: "99999999999999999999" },
      headers: auth_hdr
    expect(response).to have_http_status(422)

    get "/sentrace/internal/stats",
      params: { days: "0" },
      headers: auth_hdr
    expect(response).to have_http_status(422)
  end

  it "pre-authenticates ingestion headers before gzip inflation and enforces item, event, nesting, and field bounds" do
    compressed_payload = Zlib.gzip("{\"event_id\":\"11112222333344445555666677778888\"}\n{\"type\":\"event\"}\n{\"message\":\"nope\"}\n")
    expect(Zlib::GzipReader).not_to receive(:new)

    post "/sentrace/api/#{project.id}/envelope",
      params: compressed_payload,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "Content-Encoding" => "gzip",
        "X-Sentry-Auth" => "Sentry sentry_key=wrong_key"
      }
    expect(response).to have_http_status(:unauthorized)

    post "/sentrace/api/0/envelope",
      params: compressed_payload,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "Content-Encoding" => "gzip",
        "X-Sentry-Auth" => "Sentry sentry_key=#{dsn_key.public_key}"
      }
    expect(response).to have_http_status(:unauthorized)

    post "/sentrace/api/#{project.id}/envelope?sentry_key[]=#{dsn_key.public_key}",
      params: compressed_payload,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "Content-Encoding" => "gzip"
      }
    expect(response).to have_http_status(:unauthorized)

    # Enforce max_events_per_envelope (413) and max_envelope_items (413)
    Sentrace.configure do |config|
      config.max_events_per_envelope = 1
      config.max_envelope_items = 2
    end

    two_events = [
      "{\"event_id\":\"11112222333344445555666677778888\"}",
      "{\"type\":\"event\"}",
      "{\"event_id\":\"11112222333344445555666677778888\",\"message\":\"e1\"}",
      "{\"type\":\"event\"}",
      "{\"event_id\":\"22223333444455556666777788889999\",\"message\":\"e2\"}"
    ].join("\n") + "\n"

    post "/sentrace/api/#{project.id}/envelope",
      params: two_events,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "Sentry sentry_key=#{dsn_key.public_key}"
      }
    expect(response).to have_http_status(413)

    three_items = [
      "{}",
      "{\"type\":\"session\"}",
      "{}",
      "{\"type\":\"session\"}",
      "{}",
      "{\"type\":\"session\"}",
      "{}"
    ].join("\n") + "\n"

    post "/sentrace/api/#{project.id}/envelope",
      params: three_items,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "Sentry sentry_key=#{dsn_key.public_key}"
      }
    expect(response).to have_http_status(413)

    # Deeply nested JSON (> 64 levels) returns 400 Bad Request
    deep_json = ("{\"a\":" * 70) + "1" + ("}" * 70)
    deep_envelope = "{}\n{\"type\":\"event\"}\n#{deep_json}\n"
    post "/sentrace/api/#{project.id}/envelope",
      params: deep_envelope,
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "Sentry sentry_key=#{dsn_key.public_key}"
      }
    expect(response).to have_http_status(:bad_request)

    # Breadcrumb timestamp & fingerprint bounds
    Sentrace.reset_configuration!
    raw_bounded = {
      "event_id" => "aaaa2222bbbb3333cccc4444dddd5555",
      "message" => "Bounds check",
      "fingerprint" => Array.new(40) { |i| "fp-#{i}-#{"x" * 300}" },
      "breadcrumbs" => [
        { "category" => "ui", "message" => "long-ts", "timestamp" => "T" * 500 },
        { "category" => "ui", "message" => "bad-ts", "timestamp" => { "nested" => 1 } }
      ]
    }
    normalized_bounded = Sentrace::Ingestion::EventNormalizer.normalize(raw_bounded)
    expect(normalized_bounded.fingerprint.length).to eq(32)
    expect(normalized_bounded.fingerprint.first.bytesize).to be <= 256

    post "/sentrace/api/#{project.id}/envelope",
      params: "{}\n{\"type\":\"event\"}\n#{JSON.generate(raw_bounded)}\n",
      headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "Sentry sentry_key=#{dsn_key.public_key}"
      }
    expect(response).to have_http_status(:ok)
    stored = project.events.find_by!(event_id: "aaaa2222bbbb3333cccc4444dddd5555")
    expect(stored.event_data["breadcrumbs"][0]["timestamp"].length).to eq(64)
    expect(stored.event_data["breadcrumbs"][1]).not_to have_key("timestamp")
  end
end
