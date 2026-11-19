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

    it "redacts auth session keys while preserving non-auth *_session_id domain foreign keys and honoring allow_fields" do
      config.allow_fields = %w[token_present token_expires_in]

      normalized = build_normalized(
        "request" => {
          "url" => "https://app.example.com/calibrations?calibration_session_id=42&promotion_calibration_session_id=99&session_id=sess_1&_myapp_session=cookie_2&TOKEN_EXPIRES_IN=3600&access_token=tok_secret",
          "method" => "GET"
        },
        "tags" => {
          "calibration_session_id" => "42",
          "token_present" => "true",
          "refresh_token" => "ref_secret",
          "user_session_token" => "sess_tok_3"
        },
        "breadcrumbs" => [
          {
            "category" => "auth",
            "data" => {
              "token_expires_in" => 3600,
              "calibration_session_id" => 42,
              "_session_id" => "sess_4",
              "api_key" => "ak_live_999"
            }
          }
        ],
        "contexts" => {
          "calibration" => {
            "promotion_calibration_session_id" => 99,
            "token_present" => "Bearer leaked_jwt_value",
            "rack.session" => "rack_secret"
          }
        }
      )

      sanitized = described_class.sanitize(normalized, project_id: 1, config: config, secret_base: secret_base)
      data = sanitized.event_data
      url = data.dig("request", "url")

      expect(url).to include("calibration_session_id=42")
      expect(url).to include("promotion_calibration_session_id=99")
      expect(url).to include("TOKEN_EXPIRES_IN=3600")
      expect(url).to include("session_id=%5BREDACTED%5D")
      expect(url).to include("_myapp_session=%5BREDACTED%5D")
      expect(url).to include("access_token=%5BREDACTED%5D")

      expect(data["tags"]).to eq(
        "calibration_session_id" => "42",
        "token_present" => "true",
        "refresh_token" => "[REDACTED]",
        "user_session_token" => "[REDACTED]"
      )
      expect(data["breadcrumbs"].first["data"]).to eq(
        "token_expires_in" => 3600,
        "calibration_session_id" => 42,
        "_session_id" => "[REDACTED]",
        "api_key" => "[REDACTED]"
      )
      expect(data.dig("contexts", "calibration")).to eq(
        "promotion_calibration_session_id" => 99,
        "token_present" => "Bearer [REDACTED]",
        "rack.session" => "[REDACTED]"
      )
    end

    it "computes id_hash from user_id and userId and supports bounded opt-in retain_user_fields" do
      from_id = described_class.sanitize(
        build_normalized("user" => { "id" => "108" }),
        project_id: 1,
        config: config,
        secret_base: secret_base
      )
      from_user_id = described_class.sanitize(
        build_normalized("user" => { "user_id" => 108 }),
        project_id: 1,
        config: config,
        secret_base: secret_base
      )
      from_camel_id = described_class.sanitize(
        build_normalized("user" => { "userId" => "108" }),
        project_id: 1,
        config: config,
        secret_base: secret_base
      )

      expected_hash = from_id.event_data.dig("user", "id_hash")
      expect(from_user_id.event_data["user"]).to eq("id_hash" => expected_hash)
      expect(from_camel_id.event_data["user"]).to eq("id_hash" => expected_hash)

      config.retain_user_fields = %w[id email username name spoofed_user_id api_token password ip_address roles]
      retained = described_class.sanitize(
        build_normalized(
          "user" => {
            "id" => 108,
            "email" => "alice@internal.corp",
            "username" => "alice",
            "name" => "A" * 400,
            "spoofed_user_id" => "admin:Bearer super_secret_jwt",
            "api_token" => "tok_123",
            "password" => "hunter2",
            "ip_address" => "10.0.0.5",
            "roles" => [ "staff" ]
          }
        ),
        project_id: 1,
        config: config,
        secret_base: secret_base
      )

      user_payload = retained.event_data["user"]
      expect(user_payload["id_hash"]).to eq(expected_hash)
      expect(user_payload["id"]).to eq(108)
      expect(user_payload["email"]).to eq("alice@internal.corp")
      expect(user_payload["username"]).to eq("alice")
      expect(user_payload["name"].bytesize).to eq(256)
      expect(user_payload["spoofed_user_id"]).to eq("admin:Bearer [REDACTED]")
      expect(user_payload).not_to have_key("api_token")
      expect(user_payload).not_to have_key("password")
      expect(user_payload).not_to have_key("ip_address")
      expect(user_payload).not_to have_key("roles")
    end

    it "redacts hyphenated secret/IP keys, delimiter-bounded ssn/otp/totp, inline cloud/API/PEM secrets, and post-hook forbidden contexts" do
      config.sanitizer = lambda do |data|
        data.merge(
          "contexts" => (data["contexts"] || {}).merge(
            "env" => { "SECRET_KEY_BASE" => "reintroduced-secret" },
            "safe_ctx" => { "ok" => true }
          )
        )
      end

      jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
      pem = "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----"

      normalized = build_normalized(
        "message" => "Leak check Basic dXNlcjpwYXNz postgres://admin:dbpass@db.internal:5432/prod redis://:redispass@cache.internal:6379/0 #{jwt} snt_mcp_abcdef0123456789 AKIAIOSFODNN7EXAMPLE ghp_1234567890abcdefghijklmnopqrstuvwxyz sk_live_1234567890abcdef #{pem}",
        "tags" => {
          "x-api-key" => "ak_secret",
          "private-key" => "pk_secret",
          "x-forwarded-for" => "198.51.100.7",
          "user_ssn" => "123-45-6789",
          "login-otp" => "654321",
          "mfa.totp" => "112233",
          "classname" => "CheckoutController",
          "rootpath" => "/srv/app"
        }
      )

      sanitized = described_class.sanitize(normalized, project_id: 1, config: config, secret_base: nil)
      data = sanitized.event_data
      msg = data["message"]

      expect(msg).to include("Basic [REDACTED]")
      expect(msg).to include("postgres://[REDACTED]@db.internal:5432/prod")
      expect(msg).to include("redis://[REDACTED]@cache.internal:6379/0")
      expect(msg).not_to include("dXNlcjpwYXNz")
      expect(msg).not_to include("dbpass")
      expect(msg).not_to include("redispass")
      expect(msg).not_to include("SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")
      expect(msg).not_to include("snt_mcp_abcdef0123456789")
      expect(msg).not_to include("AKIAIOSFODNN7EXAMPLE")
      expect(msg).not_to include("ghp_1234567890abcdefghijklmnopqrstuvwxyz")
      expect(msg).not_to include("sk_live_1234567890abcdef")
      expect(msg).not_to include("MIIEvgIBADANBgkqhkiG9w0BAQEFAASC")

      expect(data["tags"]).to eq(
        "x-api-key" => "[REDACTED]",
        "private-key" => "[REDACTED]",
        "x-forwarded-for" => "[REDACTED]",
        "user_ssn" => "[REDACTED]",
        "login-otp" => "[REDACTED]",
        "mfa.totp" => "[REDACTED]",
        "classname" => "CheckoutController",
        "rootpath" => "/srv/app"
      )

      expect(data["contexts"]).to eq("safe_ctx" => { "ok" => true })
    end
  end
end
