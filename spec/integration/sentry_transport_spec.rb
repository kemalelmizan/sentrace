require "rails_helper"
require "sentry-ruby"

RSpec.describe Sentrace::SentryTransport do
  let!(:project) { Sentrace::Project.ensure!(slug: "sentry-inproc-app", name: "Sentry InProc App").first }
  let(:dsn) { project.dsn(base_url: "https://errors.example.com/sentrace") }

  before do
    Sentrace.clear_scope!
    Sentrace.configure do |config|
      config.project_slug = project.slug
      config.capture_dispatch = :inline
    end
  end

  after do
    Sentrace.clear_scope!
    Sentrace.reset_configuration!
  end

  def build_sentry_hub(dsn_str:)
    config = Sentry::Configuration.new
    config.dsn = dsn_str
    config.environment = "production"
    config.release = "2026.11.16"
    config.background_worker_threads = 0
    config.breadcrumbs_logger = []
    config.traces_sample_rate = 1.0
    config.transport.transport_class = described_class
    config.sdk_logger = Logger.new(IO::NULL)

    client = Sentry::Client.new(config)
    Sentry::Hub.new(client, Sentry::Scope.new)
  end

  it "routes sentry-ruby error events directly in-process with zero HTTP calls while discarding transactions, profiles, sessions, and client reports" do
    expect_any_instance_of(Net::HTTP).not_to receive(:request)

    hub = build_sentry_hub(dsn_str: "https://placeholder@localhost/999999")

    hub.configure_scope do |scope|
      scope.set_tags(subsystem: "inventory", secret_token: "tok_should_redact")
      scope.set_user(id: "emp_77", email: "emp@example.com")
    end
    hub.add_breadcrumb(Sentry::Breadcrumb.new(category: "warehouse", message: "reserved stock"))

    begin
      raise RuntimeError, "inventory lock contention"
    rescue RuntimeError => e
      hub.capture_exception(e)
    end

    # Unsupported Sentry transaction + manual envelope with profile, session, attachment, log, and client_report
    tx = hub.start_transaction(name: "InventoryController#reserve", op: "http.server")
    tx.finish

    transport = hub.current_client.transport
    mixed_envelope = Sentry::Envelope.new({ dsn: dsn })
    mixed_envelope.add_item({ type: "transaction" }, { event_id: SecureRandom.hex(16), type: "transaction" })
    mixed_envelope.add_item({ type: "profile" }, { profile_id: SecureRandom.hex(16) })
    mixed_envelope.add_item({ type: "session" }, { sid: SecureRandom.hex(16) })
    mixed_envelope.add_item({ type: "sessions" }, { aggregates: [] })
    mixed_envelope.add_item({ type: "attachment" }, "binary-bytes")
    mixed_envelope.add_item({ type: "log" }, { items: [] })
    mixed_envelope.add_item({ type: "client_report" }, { discarded_events: [] })
    transport.send_envelope(mixed_envelope)
    transport.flush

    expect(project.events.count).to eq(1)
    expect(project.issues.count).to eq(1)

    event = project.events.first
    expect(event.environment).to eq("production")
    expect(event.release).to eq("2026.11.16")
    expect(event.issue.exception_type).to eq("RuntimeError")
    expect(event.issue.message).to include("inventory lock contention")
    expect(event.event_data["tags"]).to include(
      "subsystem" => "inventory",
      "secret_token" => "[REDACTED]"
    )
    expect(event.event_data["breadcrumbs"].last["message"]).to eq("reserved stock")
    expect(event.event_data.dig("user", "id_hash")).to be_present
  end

  it "resolves target project from the Sentry DSN when Sentrace.configuration.project_slug is unset" do
    Sentrace.configure do |config|
      config.project_slug = nil
      config.project_id = nil
      config.capture_dispatch = :inline
    end

    hub = build_sentry_hub(dsn_str: dsn)
    hub.capture_message("DSN-resolved in-process message", level: :warning)

    expect(project.events.count).to eq(1)
    expect(project.events.first.event_data["message"]).to eq("DSN-resolved in-process message")
  end
end
