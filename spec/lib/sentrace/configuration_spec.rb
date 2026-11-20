require "rails_helper"

RSpec.describe Sentrace::Configuration do
  after { Sentrace.reset_configuration! }

  describe "defaults" do
    subject(:config) { Sentrace.configuration }

    it "applies SPEC.md payload, retention, and privacy defaults" do
      expect(config.enabled).to be(true)
      expect(config.deployment_environment).to eq("test")
      expect(config.project_slug).to be_nil
      expect(config.project_id).to be_nil
      expect(config.capture_unhandled_exceptions).to be(false)
      expect(config.sample_rate).to eq(1.0)
      expect(config.excluded_exceptions).to include("ActiveRecord::RecordNotFound", "ActionController::RoutingError", "ActionController::ParameterMissing")
      expect(config.before_send).to be_nil
      expect(config.breadcrumbs_logger).to eq([])
      expect(config.async_queue_size).to eq(256)
      expect(config.capture_dispatch).to eq(:async)
      expect(config.frontend_dsn).to be_nil
      expect(config.cors_allowed_origins).to eq([])
      expect(config.retention_period).to eq(30.days)
      expect(config.orphan_issue_retention_period).to eq(7.days)
      expect(config.retention_batch_size).to eq(1_000)
      expect(config.internal_authenticator).to be_nil
      expect(config.mcp_allowed_ips).to eq([])
      expect(config.internal_allowed_ips).to eq([])
      expect(config.mcp_rate_limit_per_minute).to eq(120)
      expect(config.mcp_auth_failure_limit_per_minute).to eq(20)
      expect(config.ingestion_rate_limit_per_minute).to be_nil
      expect(config.max_envelope_size).to eq(1.megabyte)
      expect(config.max_events_per_envelope).to eq(10)
      expect(config.max_envelope_items).to eq(50)
      expect(config.max_message_bytes).to eq(4.kilobytes)
      expect(config.max_stack_frames).to eq(50)
      expect(config.max_breadcrumbs).to eq(20)
      expect(config.max_tags).to eq(32)
      expect(config.max_tag_key_bytes).to eq(64)
      expect(config.max_tag_value_bytes).to eq(256)
      expect(config.max_context_entries).to eq(16)
      expect(config.max_context_bytes).to eq(8.kilobytes)
      expect(config.redact_fields).to eq(%w[password token authorization cookie credit_card])
      expect(config.allow_fields).to eq([])
      expect(config.retain_user_fields).to eq([])
      expect(config.sanitizer).to be_nil
      expect(config.remote_timeout).to eq(5.0)
      expect(config.remote_ping_timeout).to eq(2.5)
      expect(config.environments.keys).to eq([ :local ])
      expect(config.environments[:local].transport).to eq(:local)
    end
  end

  describe "Sentrace.configure" do
    it "applies overrides while retaining unspecified defaults" do
      Sentrace.configure do |config|
        config.retention_period = 14.days
        config.max_breadcrumbs = 10
        config.enabled = false
      end

      expect(Sentrace.configuration.retention_period).to eq(14.days)
      expect(Sentrace.configuration.max_breadcrumbs).to eq(10)
      expect(Sentrace.configuration.enabled).to be(false)
      expect(Sentrace.configuration.max_stack_frames).to eq(50)
    end

    it "retains a callable custom sanitizer" do
      custom = ->(payload) { payload }
      Sentrace.configure { |config| config.sanitizer = custom }

      expect(Sentrace.configuration.sanitizer).to eq(custom)
    end

    it "validates allow_fields and retain_user_fields as Arrays of Strings or Symbols" do
      Sentrace.configure do |config|
        config.allow_fields = [ "token_present", :token_expires_in ]
        config.retain_user_fields = %w[id email username name spoofed_user_id]
      end

      expect(Sentrace.configuration.allow_fields).to eq([ "token_present", :token_expires_in ])
      expect(Sentrace.configuration.retain_user_fields).to eq(%w[id email username name spoofed_user_id])

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.allow_fields = "token_present" }
      }.to raise_error(Sentrace::ConfigurationError, /allow_fields must be an Array/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.retain_user_fields = [ 123 ] }
      }.to raise_error(Sentrace::ConfigurationError, /retain_user_fields must be an Array/)
    end

    it "rejects non-callable custom sanitizers" do
      expect {
        Sentrace.configure { |config| config.sanitizer = "not_callable" }
      }.to raise_error(Sentrace::ConfigurationError, /sanitizer must respond to #call/)
    end

    it "validates deployment_environment is non-blank" do
      Sentrace.configure { |config| config.deployment_environment = "staging-eu" }
      expect(Sentrace.configuration.deployment_environment).to eq("staging-eu")

      expect {
        Sentrace.configure { |config| config.deployment_environment = "   " }
      }.to raise_error(Sentrace::ConfigurationError, /deployment_environment must be a non-empty/)
    end

    it "validates retention_batch_size and internal_authenticator" do
      auth_proc = ->(_req) { true }
      Sentrace.configure do |config|
        config.retention_batch_size = 500
        config.internal_authenticator = auth_proc
      end
      expect(Sentrace.configuration.retention_batch_size).to eq(500)
      expect(Sentrace.configuration.internal_authenticator).to eq(auth_proc)

      expect {
        Sentrace.configure { |config| config.retention_batch_size = 0 }
      }.to raise_error(Sentrace::ConfigurationError, /retention_batch_size must be a positive Integer/)

      Sentrace.reset_configuration!

      expect {
        Sentrace.configure { |config| config.internal_authenticator = "invalid" }
      }.to raise_error(Sentrace::ConfigurationError, /internal_authenticator must respond to #call/)
    end

    it "rejects non-positive numeric limits" do
      expect {
        Sentrace.configure { |config| config.max_stack_frames = 0 }
      }.to raise_error(Sentrace::ConfigurationError, /max_stack_frames must be a positive number/)

      Sentrace.reset_configuration!

      expect {
        Sentrace.configure { |config| config.retention_period = -5 }
      }.to raise_error(Sentrace::ConfigurationError, /retention_period must be a positive number/)
    end

    it "validates frontend_dsn, release, and cors_allowed_origins and strips DSN secrets in #inspect" do
      Sentrace.configure do |config|
        config.frontend_dsn = "https://pub123:dontleak@api.example.com/sentrace/1"
        config.release = "2026.11.16"
        config.cors_allowed_origins = [ "https://app.example.com", "http://localhost:5173" ]
      end

      cfg = Sentrace.configuration
      expect(cfg.release).to eq("2026.11.16")
      expect(cfg.cors_origin_header_for("https://app.example.com")).to eq("https://app.example.com")
      expect(cfg.cors_origin_header_for("http://localhost:5173")).to eq("http://localhost:5173")
      expect(cfg.cors_origin_header_for("https://evil.example.com")).to be_nil
      expect(cfg.inspect).not_to include("dontleak")
      expect(cfg.inspect).to include("https://pub123@api.example.com/sentrace/1")

      Sentrace.configure { |config| config.cors_allowed_origins = "*" }
      expect(Sentrace.configuration.cors_origin_header_for("https://any.example.com")).to eq("*")

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.cors_allowed_origins = 123 }
      }.to raise_error(Sentrace::ConfigurationError, /cors_allowed_origins/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.cors_allowed_origins = [ "https://app.example.com/with/path" ] }
      }.to raise_error(Sentrace::ConfigurationError, /cors_allowed_origins/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.frontend_dsn = "not-a-dsn" }
      }.to raise_error(Sentrace::ConfigurationError, /frontend_dsn is invalid/)
    end

    it "derives capture_unhandled_exceptions from project_slug/project_id unless explicitly set and validates client settings" do
      expect(Sentrace.configuration.capture_unhandled_exceptions).to be(false)

      Sentrace.configure { |config| config.project_slug = "monolith" }
      expect(Sentrace.configuration.capture_unhandled_exceptions).to be(true)

      Sentrace.configure { |config| config.capture_unhandled_exceptions = false }
      expect(Sentrace.configuration.capture_unhandled_exceptions).to be(false)

      Sentrace.reset_configuration!
      Sentrace.configure do |config|
        config.project_id = 42
        config.sample_rate = 0.5
        config.before_send = ->(ev, _hint) { ev }
        config.breadcrumbs_logger = %i[active_support_logger http_logger]
        config.async_queue_size = 512
        config.capture_dispatch = "inline"
      end
      expect(Sentrace.configuration.capture_unhandled_exceptions).to be(true)
      expect(Sentrace.configuration.capture_dispatch).to eq(:inline)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.sample_rate = 1.5 }
      }.to raise_error(Sentrace::ConfigurationError, /sample_rate/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.before_send = "invalid" }
      }.to raise_error(Sentrace::ConfigurationError, /before_send must respond to #call/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.breadcrumbs_logger = [ :unknown_logger ] }
      }.to raise_error(Sentrace::ConfigurationError, /breadcrumbs_logger/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.async_queue_size = 0 }
      }.to raise_error(Sentrace::ConfigurationError, /async_queue_size must be a positive Integer/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.capture_dispatch = :background_job }
      }.to raise_error(Sentrace::ConfigurationError, /capture_dispatch/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.project_id = -1 }
      }.to raise_error(Sentrace::ConfigurationError, /project_id/)
    end
  end

  describe "MCP environments" do
    it "registers local and remote HTTPS environments and redacts tokens in #inspect" do
      Sentrace.configure do |config|
        config.user_hash_secret = "super-secret-hmac-key"
        config.environments = {
          local: { transport: :local },
          staging: {
            transport: :http,
            url: "https://staging.example.com/sentrace/mcp",
            token: "stg-secret-token-123",
            timeout: 3.5
          },
          production: {
            transport: :http,
            url: "https://errors.example.com/sentrace/mcp",
            token: "prd-secret-token-456"
          }
        }
      end

      envs = Sentrace.configuration.environments
      expect(envs.keys).to eq([ :local, :staging, :production ])
      expect(envs[:staging].transport).to eq(:http)
      expect(envs[:staging].timeout).to eq(3.5)
      expect(envs[:production].timeout).to eq(5.0)
      expect(envs[:staging].token).to eq("stg-secret-token-123")

      inspected = Sentrace.configuration.inspect
      expect(inspected).not_to include("stg-secret-token-123")
      expect(inspected).not_to include("prd-secret-token-456")
      expect(inspected).not_to include("super-secret-hmac-key")
      expect(inspected).to include("[REDACTED]")
    end

    it "allows plain HTTP for loopback local testing hosts" do
      expect {
        Sentrace.configure do |config|
          config.environments = {
            dev_remote: { transport: :http, url: "http://127.0.0.1:3001/sentrace/mcp", token: "dev-tok" }
          }
        end
      }.not_to raise_error
    end

    it "rejects non-HTTPS URLs for non-loopback remote MCP hosts" do
      expect {
        Sentrace.configure do |config|
          config.environments = {
            staging: { transport: :http, url: "http://staging.example.com/sentrace/mcp", token: "tok" }
          }
        end
      }.to raise_error(Sentrace::ConfigurationError, /requires HTTPS for non-local host/)
    end

    it "allows :http environments with blank url or token at boot without raising ConfigurationError" do
      expect {
        Sentrace.configure do |config|
          config.remote_ping_timeout = 1.5
          config.environments = {
            local: { transport: :local },
            staging: { transport: :http, url: nil, token: nil },
            production: { transport: :http, url: "   ", token: "" }
          }
        end
      }.not_to raise_error

      expect(Sentrace.configuration.remote_ping_timeout).to eq(1.5)
      expect(Sentrace.configuration.environments.keys).to eq([ :local, :staging, :production ])

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.remote_ping_timeout = 0 }
      }.to raise_error(Sentrace::ConfigurationError, /remote_ping_timeout must be a positive number/)
    end

    it "deep-copies mutable array and environment collections on #dup" do
      original = Sentrace::Configuration.new
      copy = original.dup
      copy.excluded_exceptions << "CustomExcludedError"
      copy.redact_fields << "secret_pin"
      copy.environments = { local: { transport: :local }, staging: { transport: :http, url: nil, token: nil } }

      expect(original.excluded_exceptions).not_to include("CustomExcludedError")
      expect(original.redact_fields).not_to include("secret_pin")
      expect(original.environments.keys).to eq([ :local ])
    end

    it "rejects unsupported transports" do
      expect {
        Sentrace.configure do |config|
          config.environments = { weird: { transport: :websocket } }
        end
      }.to raise_error(Sentrace::ConfigurationError, /unsupported transport/)
    end

    it "validates max_events_per_envelope, max_envelope_items, and rejects userinfo or control chars in remote MCP settings" do
      expect {
        Sentrace.configure { |config| config.max_events_per_envelope = 0 }
      }.to raise_error(Sentrace::ConfigurationError, /max_events_per_envelope must be a positive Integer/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.max_envelope_items = -1 }
      }.to raise_error(Sentrace::ConfigurationError, /max_envelope_items must be a positive Integer/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure do |config|
          config.environments = {
            staging: { transport: :http, url: "https://user:pass@staging.example.com/sentrace/mcp", token: "tok" }
          }
        end
      }.to raise_error(Sentrace::ConfigurationError, /must not contain embedded credentials or fragments/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure do |config|
          config.environments = {
            staging: { transport: :http, url: "https://staging.example.com/sentrace/mcp", token: "bad\r\ntoken" }
          }
        end
      }.to raise_error(Sentrace::ConfigurationError, /token must not contain whitespace or control characters/)
    end

    it "validates mcp_allowed_ips, internal_allowed_ips, and rate limit settings" do
      Sentrace.configure do |config|
        config.mcp_allowed_ips = [ "10.0.0.0/8", "203.0.113.42" ]
        config.internal_allowed_ips = nil
        config.mcp_rate_limit_per_minute = 60
        config.mcp_auth_failure_limit_per_minute = 10
        config.ingestion_rate_limit_per_minute = 500
      end

      cfg = Sentrace.configuration
      expect(cfg.mcp_allowed_ips).to eq([ "10.0.0.0/8", "203.0.113.42" ])
      expect(cfg.internal_allowed_ips).to be_nil
      expect(cfg.mcp_rate_limit_per_minute).to eq(60)
      expect(cfg.mcp_auth_failure_limit_per_minute).to eq(10)
      expect(cfg.ingestion_rate_limit_per_minute).to eq(500)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.mcp_allowed_ips = [ "not-an-ip" ] }
      }.to raise_error(Sentrace::ConfigurationError, /not a valid IP or CIDR/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.internal_allowed_ips = "10.0.0.1" }
      }.to raise_error(Sentrace::ConfigurationError, /internal_allowed_ips must be an Array/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.mcp_rate_limit_per_minute = 0 }
      }.to raise_error(Sentrace::ConfigurationError, /mcp_rate_limit_per_minute must be a positive Integer or nil/)

      Sentrace.reset_configuration!
      expect {
        Sentrace.configure { |config| config.mcp_auth_failure_limit_per_minute = -3 }
      }.to raise_error(Sentrace::ConfigurationError, /mcp_auth_failure_limit_per_minute must be a positive Integer or nil/)
    end
  end
end
