require "rails_helper"
require "sentry-ruby"

RSpec.describe Sentrace::Dsn do
  describe ".build" do
    it "formats a DSN with an engine mount prefix" do
      dsn = described_class.build(
        base_url: "https://errors.example.com/sentrace",
        public_key: "a1b2c3d4",
        project_id: 1
      )

      expect(dsn.to_s).to eq("https://a1b2c3d4@errors.example.com/sentrace/1")
      expect(dsn.path_prefix).to eq("/sentrace")
      expect(dsn.project_id).to eq("1")
      expect(dsn.envelope_endpoint).to eq("https://errors.example.com/sentrace/api/1/envelope/")
    end

    it "formats a root-domain DSN without extra slashes and preserves custom ports" do
      dsn = described_class.build(
        base_url: "http://localhost:3000/",
        public_key: "pub123",
        project_id: 42
      )

      expect(dsn.to_s).to eq("http://pub123@localhost:3000/42")
      expect(dsn.path_prefix).to eq("")
      expect(dsn.port).to eq(3000)
      expect(dsn.envelope_endpoint).to eq("http://localhost:3000/api/42/envelope/")
    end

    it "redacts optional secret keys in #inspect" do
      dsn = described_class.build(
        base_url: "https://errors.example.com",
        public_key: "pub123",
        secret_key: "topsecret",
        project_id: 7
      )

      expect(dsn.to_s).to eq("https://pub123:topsecret@errors.example.com/7")
      expect(dsn.inspect).not_to include("topsecret")
      expect(dsn.inspect).to include("[REDACTED]")
    end
  end

  describe ".parse" do
    it "extracts scheme, public_key, host, path_prefix, and project_id" do
      dsn = described_class.parse("https://a1b2c3d4@errors.example.com/sentrace/1")

      expect(dsn.scheme).to eq("https")
      expect(dsn.public_key).to eq("a1b2c3d4")
      expect(dsn.secret_key).to be_nil
      expect(dsn.host).to eq("errors.example.com")
      expect(dsn.port).to eq(443)
      expect(dsn.path_prefix).to eq("/sentrace")
      expect(dsn.project_id).to eq("1")
    end

    it "rejects malformed DSNs missing public_key, host, scheme, or project_id" do
      [
        nil,
        "",
        "https://errors.example.com/1",
        "https://a1b2c3d4@errors.example.com/",
        "ftp://a1b2c3d4@errors.example.com/1",
        "not a url at all"
      ].each do |invalid_input|
        expect {
          described_class.parse(invalid_input)
        }.to raise_error(Sentrace::InvalidDsnError), "expected #{invalid_input.inspect} to fail"
      end
    end
  end

  describe "sentry-ruby Sentry::DSN compatibility" do
    it "produces DSNs whose envelope URL matches Sentry::DSN for both root and mounted paths" do
      mounted = described_class.build(
        base_url: "https://errors.example.com/sentrace",
        public_key: "deadbeef12345678",
        project_id: 99
      )
      sentry_mounted = Sentry::DSN.new(mounted.to_s)
      expect(sentry_mounted.public_key).to eq("deadbeef12345678")
      expect(sentry_mounted.project_id).to eq("99")
      expect(sentry_mounted.envelope_endpoint).to eq("/sentrace/api/99/envelope/")
      expect("#{sentry_mounted.server}#{sentry_mounted.envelope_endpoint}").to eq(
        "https://errors.example.com/sentrace/api/99/envelope/"
      )

      root = described_class.build(
        base_url: "http://127.0.0.1:3000",
        public_key: "cafebabe87654321",
        project_id: 1
      )
      sentry_root = Sentry::DSN.new(root.to_s)
      expect("#{sentry_root.server}#{sentry_root.envelope_endpoint}").to eq(
        "http://127.0.0.1:3000/api/1/envelope/"
      )
    end
  end
end
