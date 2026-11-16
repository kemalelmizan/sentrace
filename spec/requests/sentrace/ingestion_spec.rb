require "rails_helper"
require "zlib"

RSpec.describe "Sentrace Envelope Ingestion API", type: :request do
  let!(:provisioned) { Sentrace::Project.provision!(slug: "shop-api", name: "Shop API") }
  let(:project) { provisioned.first }
  let(:project_key) { provisioned.last }
  let(:endpoint) { "/sentrace/api/#{project.id}/envelope/" }
  let(:sentry_auth_header) do
    "Sentry sentry_version=7, sentry_client=sentry-ruby/5.28.1, sentry_timestamp=1763294400, sentry_key=#{project_key.public_key}"
  end

  around do |example|
    Sentrace.reset_configuration!
    example.run
  ensure
    Sentrace.reset_configuration!
  end

  def build_envelope(events: [], extra_items: [], headers: {})
    buf = "".b
    buf << headers.to_json.b << "\n".b
    events.each do |ev|
      payload = ev.is_a?(String) ? ev : ev.to_json
      buf << { type: "event", length: payload.bytesize }.to_json.b << "\n".b << payload.b << "\n".b
    end
    extra_items.each do |(item_header, raw_payload)|
      buf << item_header.to_json.b << "\n".b << raw_payload.b << "\n".b
    end
    buf
  end

  describe "authentication" do
    it "accepts valid X-Sentry-Auth requests and returns 200 with accepted event id" do
      event_id = "0123456789abcdef0123456789abcdef"
      body = build_envelope(events: [ { event_id: event_id, message: "Checkout failed" } ])

      post endpoint, params: body, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => sentry_auth_header
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("id" => event_id)
      expect(project.events.count).to eq(1)
      expect(project.issues.count).to eq(1)
    end

    it "authenticates via envelope header dsn when X-Sentry-Auth is omitted" do
      dsn = project.dsn(base_url: "https://errors.example.com/sentrace")
      event_id = "abcdef0123456789abcdef0123456789"
      body = build_envelope(
        headers: { event_id: event_id, dsn: dsn },
        events: [ { event_id: event_id, message: "Via envelope DSN" } ]
      )

      post "/sentrace/api/#{project.id}/envelope", params: body, headers: {
        "Content-Type" => "application/x-sentry-envelope"
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("id" => event_id)
    end

    it "rejects revoked, mismatched, or missing credentials with HTTP 401 before persisting anything" do
      body = build_envelope(events: [ { event_id: SecureRandom.hex(16), message: "Should reject" } ])

      post endpoint, params: body, headers: { "Content-Type" => "application/x-sentry-envelope" }
      expect(response).to have_http_status(:unauthorized)

      project_key.revoke!
      post endpoint, params: body, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => sentry_auth_header
      }
      expect(response).to have_http_status(:unauthorized)
      expect(Sentrace::Event.count).to eq(0)
      expect(Sentrace::Issue.count).to eq(0)
    end

    it "enforces secret_digest when a secret is configured on the project key" do
      project_key.update!(secret: "s3cr3t-value")
      body = build_envelope(events: [ { event_id: SecureRandom.hex(16), message: "Secret check" } ])

      post endpoint, params: body, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => sentry_auth_header
      }
      expect(response).to have_http_status(:unauthorized)

      post endpoint, params: body, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => "#{sentry_auth_header}, sentry_secret=s3cr3t-value"
      }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "request size and gzip decompression limits" do
    it "rejects oversized raw payloads with HTTP 413 before parsing" do
      Sentrace.configuration.max_envelope_size = 1024
      oversized_body = "x" * 2048

      expect(Sentrace::Ingestion::EnvelopeParser).not_to receive(:parse)

      post endpoint, params: oversized_body, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => sentry_auth_header
      }

      expect(response).to have_http_status(:content_too_large)
      expect(Sentrace::Event.count).to eq(0)
    end

    it "inflates valid gzip-compressed envelopes within max_envelope_size" do
      event_id = "fedcba9876543210fedcba9876543210"
      raw_envelope = build_envelope(events: [ { event_id: event_id, message: "Compressed error" } ])
      compressed = Zlib.gzip(raw_envelope)

      post endpoint, params: compressed, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "Content-Encoding" => "gzip",
        "X-Sentry-Auth" => sentry_auth_header
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("id" => event_id)
      expect(project.events.find_by!(event_id: event_id).event_data["message"]).to eq("Compressed error")
    end

    it "aborts inflation and returns HTTP 413 when a gzip bomb expands past max_envelope_size" do
      Sentrace.configuration.max_envelope_size = 2048
      # Highly compressible payload: tiny compressed body (< 200 bytes), > 16 KB decompressed
      bomb_raw = build_envelope(events: [ { event_id: SecureRandom.hex(16), message: "A" * 20_000 } ])
      compressed_bomb = Zlib.gzip(bomb_raw)
      expect(compressed_bomb.bytesize).to be < 512

      post endpoint, params: compressed_bomb, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "Content-Encoding" => "gzip",
        "X-Sentry-Auth" => sentry_auth_header
      }

      expect(response).to have_http_status(:content_too_large)
      expect(Sentrace::Event.count).to eq(0)
    end
  end

  describe "multi-item discarding, deduplication, and error safety" do
    it "persists only error events and creates zero rows for transactions, sessions, and binary attachments" do
      binary_blob = "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR\nembedded\n".b
      tx_json = { type: "transaction", transaction: "GET /health" }.to_json
      session_json = { sid: "123", status: "ok" }.to_json

      body = build_envelope(
        events: [
          { event_id: "11111111111111111111111111111111", message: "Error 1" },
          { event_id: "22222222222222222222222222222222", message: "Error 2" }
        ],
        extra_items: [
          [ { type: "transaction", length: tx_json.bytesize }, tx_json ],
          [ { type: "session", length: session_json.bytesize }, session_json ],
          [ { type: "attachment", length: binary_blob.bytesize }, binary_blob ]
        ]
      )

      post endpoint, params: body, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => sentry_auth_header
      }

      expect(response).to have_http_status(:ok)
      expect(project.events.count).to eq(2)

      telemetry_only = build_envelope(
        events: [],
        extra_items: [
          [ { type: "transaction", length: tx_json.bytesize }, tx_json ],
          [ { type: "session", length: session_json.bytesize }, session_json ]
        ]
      )

      expect {
        post endpoint, params: telemetry_only, headers: {
          "Content-Type" => "application/x-sentry-envelope",
          "X-Sentry-Auth" => sentry_auth_header
        }
      }.not_to change { [ Sentrace::Issue.count, Sentrace::Event.count ] }

      expect(response).to have_http_status(:ok)
    end

    it "deduplicates repeated deliveries of the same event_id without incrementing event_count" do
      event_id = "99999999999999999999999999999999"
      body = build_envelope(events: [ { event_id: event_id, message: "Duplicate test" } ])
      req_headers = {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => sentry_auth_header
      }

      2.times { post endpoint, params: body, headers: req_headers }

      expect(response).to have_http_status(:ok)
      expect(project.events.where(event_id: event_id).count).to eq(1)
      expect(project.issues.first.event_count).to eq(1)
    end

    it "returns HTTP 400 on malformed JSON and HTTP 500 without internal leakage on unexpected errors" do
      post endpoint, params: "{broken-header\n", headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => sentry_auth_header
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.body).not_to include("JSON::ParserError")

      allow(Sentrace::Ingestion::Processor).to receive(:process_raw_envelope)
        .and_raise(RuntimeError, "PG::ConnectionBad password=topsecret host=db.internal")

      valid_body = build_envelope(events: [ { event_id: SecureRandom.hex(16), message: "Trigger 500" } ])
      post endpoint, params: valid_body, headers: {
        "Content-Type" => "application/x-sentry-envelope",
        "X-Sentry-Auth" => sentry_auth_header
      }

      expect(response).to have_http_status(:internal_server_error)
      expect(response.parsed_body).to eq("error" => "Internal ingestion error")
      expect(response.body).not_to include("topsecret")
      expect(response.body).not_to include("db.internal")
    end
  end

  describe "browser CORS preflight and query-string authentication" do
    it "responds to OPTIONS preflight and attaches CORS headers for allowed origins while omitting them for unlisted origins" do
      Sentrace.configure do |config|
        config.cors_allowed_origins = [ "https://spa.example.com" ]
      end

      process :options, "/sentrace/api/#{project.id}/envelope", headers: {
        "Origin" => "https://spa.example.com",
        "Access-Control-Request-Method" => "POST"
      }

      expect(response).to have_http_status(:no_content)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("https://spa.example.com")
      expect(response.headers["Vary"]).to include("Origin")
      expect(response.headers["Access-Control-Allow-Methods"]).to eq("POST, OPTIONS")

      event_id = "abababababababababababababababab"
      body = build_envelope(events: [ { event_id: event_id, platform: "javascript", message: "SPA error" } ])
      post "/sentrace/api/#{project.id}/envelope?sentry_key=#{project_key.public_key}&sentry_version=7&sentry_client=sentrace-js/0.1.0",
        params: body,
        headers: {
          "Origin" => "https://spa.example.com",
          "Content-Type" => "text/plain;charset=UTF-8"
        }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("https://spa.example.com")
      expect(response.parsed_body).to eq("id" => event_id)

      process :options, "/sentrace/api/#{project.id}/envelope", headers: {
        "Origin" => "https://evil.example.com"
      }
      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end
  end
end
