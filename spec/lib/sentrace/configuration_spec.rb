require "rails_helper"

RSpec.describe Sentrace::Configuration do
  after { Sentrace.reset_configuration! }

  describe "defaults" do
    subject(:config) { Sentrace.configuration }

    it "applies SPEC.md payload, retention, and privacy defaults" do
      expect(config.enabled).to be(true)
      expect(config.retention_period).to eq(30.days)
      expect(config.orphan_issue_retention_period).to eq(7.days)
      expect(config.max_envelope_size).to eq(1.megabyte)
      expect(config.max_message_bytes).to eq(4.kilobytes)
      expect(config.max_stack_frames).to eq(50)
      expect(config.max_breadcrumbs).to eq(20)
      expect(config.max_tags).to eq(32)
      expect(config.max_tag_key_bytes).to eq(64)
      expect(config.max_tag_value_bytes).to eq(256)
      expect(config.max_context_entries).to eq(16)
      expect(config.max_context_bytes).to eq(8.kilobytes)
      expect(config.redact_fields).to eq(%w[password token authorization cookie credit_card])
      expect(config.sanitizer).to be_nil
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

    it "rejects non-callable custom sanitizers" do
      expect {
        Sentrace.configure { |config| config.sanitizer = "not_callable" }
      }.to raise_error(Sentrace::ConfigurationError, /sanitizer must respond to #call/)
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

    it "rejects unsupported transports" do
      expect {
        Sentrace.configure do |config|
          config.environments = { weird: { transport: :websocket } }
        end
      }.to raise_error(Sentrace::ConfigurationError, /unsupported transport/)
    end
  end
end
