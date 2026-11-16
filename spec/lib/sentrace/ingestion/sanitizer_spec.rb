require "rails_helper"

RSpec.describe Sentrace::Ingestion::Sanitizer do
  let(:config) { Sentrace::Configuration.new }
  let(:secret_base) { "test-secret-key-base-for-hmac" }

  def build_normalized(raw_overrides)
    base_raw = {
      "event_id" => "0123456789abcdef0123456789abcdef",
      "timestamp" => "2026-11-16T12:00:00Z",
      "message" => "Order check"
    }.merge(raw_overrides)

    Sentrace::Ingestion::EventNormalizer.normalize(base_raw, config: config)
  end

  describe ".sanitize" do
    it "strips request bodies, cookies, auth headers, IPs, and env vars, keeping only sanitized url and method" do
      normalized = build_normalized(
        "request" => {
          "url" => "https://user:pass@app.example.com/orders?page=2&api_token=tok_secret&password=p1",
          "query_string" => "session_id=sess_99",
          "method" => "post",
          "data" => { "card" => "4111111111111111", "password" => "hunter2" },
          "cookies" => "_app_session=abcdef",
          "headers" => {
            "Authorization" => "Bearer super-secret-jwt",
            "Cookie" => "_app_session=abcdef",
            "X-Forwarded-For" => "203.0.113.9"
          },
          "env" => {
            "REMOTE_ADDR" => "203.0.113.9",
            "AWS_SECRET_ACCESS_KEY" => "aws-secret"
          }
        },
        "contexts" => {
          "env" => { "DATABASE_URL" => "postgres://u:p@host/db" },
          "headers" => { "Authorization" => "Bearer xyz" },
          "runtime" => { "name" => "ruby", "version" => "3.3.13" }
        }
      )

      sanitized = described_class.sanitize(normalized, project_id: 1, config: config, secret_base: secret_base)

      req = sanitized.event_data["request"]
      expect(req.keys).to match_array(%w[url method])
      expect(req["method"]).to eq("POST")
      expect(req["url"]).to include("https://app.example.com/orders?")
      expect(req["url"]).to include("page=2")
      expect(req["url"]).not_to include("user:pass")
      expect(req["url"]).not_to include("tok_secret")
      expect(req["url"]).not_to include("p1")
      expect(req["url"]).not_to include("sess_99")
      expect(req["url"]).to include("api_token=%5BREDACTED%5D")

      expect(sanitized.event_data["contexts"]).to eq("runtime" => { "name" => "ruby", "version" => "3.3.13" })
      expect(sanitized.raw_request).to be_nil
    end

    it "recursively redacts configured fields, bearer tokens, and Luhn-valid payment cards across tags, breadcrumbs, contexts, and messages" do
      config.redact_fields += [ "ssn" ]

      normalized = build_normalized(
        "message" => "Auth failed for Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig with card 4111-1111-1111-1111",
        "tags" => {
          "api_token" => "secret123",
          "component" => "auth",
          "client_ip" => "198.51.100.42"
        },
        "breadcrumbs" => [
          {
            "category" => "http",
            "message" => "Sent Authorization Bearer tok_live_987",
            "data" => { "password" => "hunter2", "status_code" => 401 }
          }
        ],
        "contexts" => {
          "payment" => {
            "password" => "hunter2",
            "credit_card" => "4111-1111-1111-1111",
            "customer_ssn" => "123-45-6789",
            "raw_note" => "Charged 4111 1111 1111 1111",
            "currency" => "USD"
          }
        }
      )

      sanitized = described_class.sanitize(normalized, project_id: 1, config: config, secret_base: secret_base)
      data = sanitized.event_data

      expect(data["message"]).to eq("Auth failed for Bearer [REDACTED] with card [REDACTED]")
      expect(data["tags"]).to eq(
        "api_token" => "[REDACTED]",
        "component" => "auth",
        "client_ip" => "[REDACTED]"
      )
      expect(data["breadcrumbs"].first["message"]).to eq("Sent Authorization Bearer [REDACTED]")
      expect(data["breadcrumbs"].first["data"]).to eq("password" => "[REDACTED]", "status_code" => 401)
      expect(data["contexts"]["payment"]).to eq(
        "password" => "[REDACTED]",
        "credit_card" => "[REDACTED]",
        "customer_ssn" => "[REDACTED]",
        "raw_note" => "Charged [REDACTED]",
        "currency" => "USD"
      )
    end

    it "replaces user context with a project-scoped HMAC-SHA256 id_hash and strips email, username, and IP" do
      raw_user = {
        "id" => "42",
        "email" => "alice@example.com",
        "username" => "alice",
        "ip_address" => "203.0.113.5"
      }

      event_p1 = described_class.sanitize(
        build_normalized("user" => raw_user),
        project_id: 1,
        config: config,
        secret_base: secret_base
      )
      event_p1_repeat = described_class.sanitize(
        build_normalized("user" => raw_user),
        project_id: 1,
        config: config,
        secret_base: secret_base
      )
      event_p2 = described_class.sanitize(
        build_normalized("user" => raw_user),
        project_id: 2,
        config: config,
        secret_base: secret_base
      )

      user_p1 = event_p1.event_data["user"]
      user_p2 = event_p2.event_data["user"]

      expect(user_p1.keys).to eq([ "id_hash" ])
      expect(user_p1["id_hash"]).to match(/\A[0-9a-f]{64}\z/)
      expect(user_p1["id_hash"]).to eq(event_p1_repeat.event_data.dig("user", "id_hash"))
      expect(user_p1["id_hash"]).not_to eq(user_p2["id_hash"])
      expect(event_p1.raw_user).to be_nil
    end

    it "falls back to hashing email when id is absent without retaining raw email" do
      sanitized = described_class.sanitize(
        build_normalized("user" => { "email" => "only-email@example.com", "ip_address" => "203.0.113.5" }),
        project_id: 1,
        config: config,
        secret_base: secret_base
      )

      expect(sanitized.event_data["user"].keys).to eq([ "id_hash" ])
      expect(sanitized.event_data.dig("user", "id_hash")).to match(/\A[0-9a-f]{64}\z/)
      expect(JSON.generate(sanitized.event_data)).not_to include("only-email@example.com")
    end

    it "executes custom host sanitizer hook and re-enforces payload bounds afterward" do
      config.max_message_bytes = 16
      config.sanitizer = lambda do |data|
        data.merge(
          "message" => "A" * 100,
          "tags" => (data["tags"] || {}).merge("scrubbed_by" => "host")
        )
      end

      sanitized = described_class.sanitize(
        build_normalized("tags" => { "env_tier" => "gold" }),
        project_id: 1,
        config: config,
        secret_base: secret_base
      )

      expect(sanitized.event_data.dig("tags", "scrubbed_by")).to eq("host")
      expect(sanitized.event_data["message"].bytesize).to eq(16)
    end
  end
end
