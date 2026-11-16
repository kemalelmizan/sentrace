require "rails_helper"

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

    expect(response).to have_http_status(:content_too_large)
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
end
