require "rails_helper"
require "sentry-ruby"

RSpec.describe "Official sentry-ruby SDK Compatibility" do
  RackTransportResponse = Data.define(:code, :body, :headers) do
    def [](key)
      headers[key] || headers[key.downcase]
    end
  end

  let!(:provisioned) { Sentrace::Project.provision!(slug: "rails-host-app", name: "Rails Host App") }
  let(:project) { provisioned.first }
  let(:dsn) { project.dsn(base_url: "http://example.org/sentrace") }

  let(:rack_transport_class) do
    Class.new(Sentry::HTTPTransport) do
      class << self
        attr_accessor :requests_sent
      end
      self.requests_sent = []

      def do_request(endpoint, headers, body)
        self.class.requests_sent << { endpoint: endpoint, headers: headers, bytesize: body.bytesize }

        rack_env = {
          "CONTENT_TYPE" => headers["Content-Type"],
          "CONTENT_LENGTH" => body.bytesize.to_s,
          "HTTP_USER_AGENT" => headers["User-Agent"]
        }
        rack_env["HTTP_CONTENT_ENCODING"] = headers["Content-Encoding"] unless headers["Content-Encoding"].to_s.empty?
        rack_env["HTTP_X_SENTRY_AUTH"] = headers["X-Sentry-Auth"] if headers["X-Sentry-Auth"]

        mock_request = Rack::MockRequest.new(Rails.application)
        status, resp_headers, resp_body_enum = mock_request.post(endpoint, rack_env.merge(input: body)).to_a
        body_str = "".b
        resp_body_enum.each { |part| body_str << part.b }

        RackTransportResponse.new(
          code: status.to_s,
          body: body_str,
          headers: resp_headers.transform_keys(&:downcase)
        )
      end
    end
  end

  def with_sentry_sdk(dsn_str:, environment: "staging", release: "v1.2.3", traces_sample_rate: nil)
    config = Sentry::Configuration.new
    config.dsn = dsn_str
    config.environment = environment
    config.release = release
    config.background_worker_threads = 0
    config.breadcrumbs_logger = []
    config.traces_sample_rate = traces_sample_rate if traces_sample_rate
    config.transport.transport_class = rack_transport_class
    config.sdk_logger = Logger.new(IO::NULL)

    client = Sentry::Client.new(config)
    hub = Sentry::Hub.new(client, Sentry::Scope.new)
    yield(hub)
  end

  it "captures exceptions with stack frames, breadcrumbs, tags, sanitized user hash, and release/environment metadata" do
    with_sentry_sdk(dsn_str: dsn, environment: "staging", release: "2026.11.16-rc1") do |hub|
      hub.configure_scope do |scope|
        scope.set_tags(component: "billing", api_token: "live_secret_token")
        scope.set_user(id: "user_88", email: "private@example.com", ip_address: "198.51.100.7")
      end

      crumb = Sentry::Breadcrumb.new(
        category: "checkout.step",
        message: "Validated cart items",
        level: "info",
        data: { "cart_size" => 3, "password" => "should_redact" }
      )
      hub.add_breadcrumb(crumb)

      begin
        begin
          raise ArgumentError, "invalid cents amount"
        rescue ArgumentError
          raise StandardError, "Charge execution failed"
        end
      rescue StandardError => e
        hub.capture_exception(e)
      end
    end

    expect(project.issues.count).to eq(1)
    expect(project.events.count).to eq(1)

    issue = project.issues.first
    event = project.events.first

    expect(issue.exception_type).to eq("StandardError")
    expect(issue.message).to include("Charge execution failed")
    expect(issue.event_count).to eq(1)
    expect(issue.status).to eq("unresolved")

    expect(event.environment).to eq("staging")
    expect(event.release).to eq("2026.11.16-rc1")
    expect(event.platform).to eq("ruby")
    expect(event.level).to eq("level_error").or eq("error")
    expect(event.event_data.dig("exception", "type")).to eq("StandardError")
    expect(event.event_data.dig("exception", "frames")).to be_an(Array)
    expect(event.event_data.dig("exception", "frames")).not_to be_empty

    expect(event.event_data["tags"]).to include(
      "component" => "billing",
      "api_token" => "[REDACTED]"
    )
    expect(event.event_data["breadcrumbs"].last).to include(
      "category" => "checkout.step",
      "message" => "Validated cart items",
      "data" => { "cart_size" => 3, "password" => "[REDACTED]" }
    )
    expect(event.event_data["user"].keys).to eq([ "id_hash" ])
    expect(JSON.generate(event.event_data)).not_to include("private@example.com")
    expect(JSON.generate(event.event_data)).not_to include("198.51.100.7")
  end

  it "captures Sentry messages, handles automatic SDK gzip compression (>= 30 KB), and discards SDK transactions" do
    with_sentry_sdk(dsn_str: dsn, environment: "production", release: "v2.0.0", traces_sample_rate: 1.0) do |hub|
      # Force envelope size >= 30 KB so Sentry::HTTPTransport compresses with Zlib.gzip automatically
      40.times do |idx|
        hub.add_breadcrumb(
          Sentry::Breadcrumb.new(
            category: "verbose.log",
            message: "Padding breadcrumb #{idx} " + ("x" * 900)
          )
        )
      end

      hub.capture_message("Payment webhook signature mismatch for order 55192", level: :warning)

      transaction = hub.start_transaction(name: "OrdersController#create", op: "http.server")
      transaction.finish
    end

    gzip_requests = rack_transport_class.requests_sent.select { |r| r[:headers]["Content-Encoding"] == "gzip" }
    expect(gzip_requests).not_to be_empty

    # Only the message event creates rows; the finished transaction envelope is cleanly discarded!
    expect(project.events.count).to eq(1)
    expect(project.issues.count).to eq(1)

    stored = project.events.first
    expect(stored.environment).to eq("production")
    expect(stored.event_data["breadcrumbs"].size).to eq(Sentrace.configuration.max_breadcrumbs)
    expect(stored.event_data["message"]).to eq("Payment webhook signature mismatch for order 55192")
  end
end
