require "rails_helper"

RSpec.describe "Automatic Rack/Rails, Sidekiq, and ActiveJob Integrations" do
  let!(:project) { Sentrace::Project.ensure!(slug: "monolith-integrations", name: "Monolith Integrations").first }

  before do
    Sentrace.clear_scope!
    Sentrace::Integrations::ExceptionDeduplicator.reset!
    Sentrace.configure do |config|
      config.project_slug = project.slug
      config.capture_dispatch = :inline
    end
  end

  after do
    Sentrace.clear_scope!
    Sentrace::Integrations::ExceptionDeduplicator.reset!
    Sentrace.reset_configuration!
  end

  describe "Sentrace::Integrations::RackMiddleware" do
    it "is registered in the Rails middleware stack" do
      middlewares = Rails.application.middleware.map(&:klass)
      expect(middlewares).to include(Sentrace::Integrations::RackMiddleware)
    end

    it "isolates per-request scope, skips excluded 404 exceptions, captures unhandled 500s with sanitized URL and X-Request-Id, and re-raises" do
      route_behavior = :not_found
      downstream_app = lambda do |env|
        case route_behavior
        when :not_found
          Sentrace.set_tag("leaked_from_404", "yes")
          raise ActiveRecord::RecordNotFound, "Order 99 not found"
        when :crash
          Sentrace.set_tag("tenant", "acme")
          Sentrace.add_breadcrumb(category: "checkout", message: "authorizing payment")
          raise RuntimeError, "gateway socket closed"
        when :ok
          Sentrace.capture_message("healthy follow-up request")
          [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ]
        end
      end

      middleware = Sentrace::Integrations::RackMiddleware.new(downstream_app)

      # 1. Excluded exception (RecordNotFound) is NOT captured and does NOT leak scope
      env_404 = Rack::MockRequest.env_for("https://shop.example.com/orders/99", method: "GET")
      expect { middleware.call(env_404) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(project.events.count).to eq(0)

      # 2. Unhandled RuntimeError IS captured with sanitized URL + request_id and re-raised
      route_behavior = :crash
      env_500 = Rack::MockRequest.env_for(
        "https://shop.example.com/orders?token=sec_abc&calibration_session_id=44",
        "REQUEST_METHOD" => "POST",
        "action_dispatch.request_id" => "req-rack-778899",
        "action_dispatch.request.path_parameters" => { controller: "orders", action: "create" }
      )
      expect { middleware.call(env_500) }.to raise_error(RuntimeError, "gateway socket closed")
      expect(project.events.count).to eq(1)

      crash_event = project.events.order(:id).last
      expect(crash_event.culprit).to eq("OrdersController#create")
      expect(crash_event.event_data.dig("exception", "mechanism")).to eq("type" => "rack", "handled" => false)
      expect(crash_event.event_data["tags"]).to include(
        "tenant" => "acme",
        "request_id" => "req-rack-778899"
      )
      expect(crash_event.event_data["tags"]).not_to have_key("leaked_from_404")
      expect(crash_event.event_data.dig("request", "method")).to eq("POST")
      expect(crash_event.event_data.dig("request", "url")).to include("token=%5BREDACTED%5D")
      expect(crash_event.event_data.dig("request", "url")).to include("calibration_session_id=44")
      expect(crash_event.event_data["breadcrumbs"].map { |c| c["message"] }).to eq([ "authorizing payment" ])

      # 3. Subsequent request on the same thread starts with a clean scope
      route_behavior = :ok
      env_200 = Rack::MockRequest.env_for("https://shop.example.com/health", method: "GET")
      status, _, _ = middleware.call(env_200)
      expect(status).to eq(200)

      followup_event = project.events.order(:id).last
      expect(followup_event.event_data["tags"]).not_to have_key("tenant")
      expect(followup_event.event_data["breadcrumbs"]).to eq([])
    end
  end

  describe "Sentrace::Integrations::ActiveJob and Sidekiq (with deduplication)" do
    let(:failing_job_class) do
      Class.new(ActiveJob::Base) do
        self.queue_adapter = :inline
        queue_as :critical

        def self.name
          "InvoiceGenerationJob"
        end

        def perform(order_id)
          Sentrace.set_tag("order_id", order_id.to_s)
          Sentrace.add_breadcrumb(category: "pdf", message: "rendering template")
          raise StandardError, "PDF renderer crashed for order #{order_id}"
        end
      end
    end

    it "captures unhandled ActiveJob exceptions with active_job context and isolates scope" do
      expect {
        failing_job_class.perform_now(501)
      }.to raise_error(StandardError, /PDF renderer crashed for order 501/)

      expect(project.events.count).to eq(1)
      event = project.events.first
      expect(event.culprit).to eq("InvoiceGenerationJob")
      expect(event.event_data.dig("exception", "mechanism")).to eq("type" => "active_job", "handled" => false)
      expect(event.event_data["tags"]).to include("order_id" => "501", "queue" => "critical")
      expect(event.event_data.dig("contexts", "active_job")).to include(
        "job_class" => "InvoiceGenerationJob",
        "queue_name" => "critical"
      )
      expect(Sentrace.current_scope.tags).to be_empty
    end

    it "wires Sidekiq server middleware, error handlers, and lifecycle flush hooks and deduplicates ActiveJob-on-Sidekiq errors" do
      middleware_chain = Class.new do
        attr_reader :entries
        def initialize = (@entries = [])
        def exists?(klass) = @entries.include?(klass)
        def add(klass) = (@entries << klass)
      end.new

      lifecycle_events = {}
      fake_sidekiq_config = Struct.new(:chain, :error_handlers, :events) do
        def server_middleware
          yield(chain)
        end

        def on(event_name, &block)
          (events[event_name] ||= []) << block
        end
      end.new(middleware_chain, [], lifecycle_events)

      fake_sidekiq_mod = Module.new do
        define_singleton_method(:configure_server) do |&block|
          block.call(fake_sidekiq_config)
        end
      end

      Sentrace::Integrations::Sidekiq.install!(fake_sidekiq_mod)
      Sentrace::Integrations::Sidekiq.install!(fake_sidekiq_mod) # idempotent

      expect(middleware_chain.entries).to eq([ Sentrace::Integrations::Sidekiq::ServerMiddleware ])
      expect(fake_sidekiq_config.error_handlers.size).to eq(1)
      expect(lifecycle_events.keys).to contain_exactly(:quiet, :shutdown)

      server_mw = middleware_chain.entries.first.new
      error_handler = fake_sidekiq_config.error_handlers.first

      # Case 1: Native Sidekiq worker (non-ActiveJob) raising an unhandled exception
      raw_sidekiq_job = {
        "class" => "HardSyncWorker",
        "jid" => "jid_abc123",
        "queue" => "sync",
        "retry_count" => 2
      }

      expect {
        begin
          server_mw.call(Object.new, raw_sidekiq_job, "sync") do
            Sentrace.set_tag("sync_batch", "batch-7")
            Sentrace.add_breadcrumb(category: "sidekiq.step", message: "fetched batch 7")
            raise RuntimeError, "ERP upstream timeout"
          end
        rescue RuntimeError => e
          error_handler.call(e, { job: raw_sidekiq_job })
          raise
        end
      }.to raise_error(RuntimeError, "ERP upstream timeout")

      expect(project.events.count).to eq(1)
      sk_event = project.events.order(:id).last
      expect(sk_event.culprit).to eq("HardSyncWorker")
      expect(sk_event.event_data.dig("exception", "mechanism")).to eq("type" => "sidekiq", "handled" => false)
      expect(sk_event.event_data["tags"]).to include("sync_batch" => "batch-7", "queue" => "sync")
      expect(sk_event.event_data.dig("contexts", "sidekiq")).to eq(
        "queue" => "sync",
        "jid" => "jid_abc123",
        "class" => "HardSyncWorker",
        "retry_count" => 2
      )
      expect(sk_event.event_data["breadcrumbs"].map { |c| c["message"] }).to eq([ "fetched batch 7" ])
      expect(Sentrace.current_scope.tags).to be_empty

      # Case 2: ActiveJob running atop Sidekiq MUST capture exactly ONCE (never double-captured!)
      wrapped_aj_job = {
        "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
        "wrapped" => "InvoiceGenerationJob",
        "jid" => "jid_wrapped_999",
        "queue" => "critical",
        "retry_count" => 0
      }

      expect {
        begin
          server_mw.call(Object.new, wrapped_aj_job, "critical") do
            failing_job_class.perform_now(888)
          end
        rescue StandardError => e
          error_handler.call(e, { job: wrapped_aj_job })
          raise
        end
      }.to raise_error(StandardError, /PDF renderer crashed for order 888/)

      # Total events: 1 (from Case 1) + 1 (from Case 2) == 2 (NOT 3!)
      expect(project.events.count).to eq(2)
      aj_sk_event = project.events.order(:id).last
      expect(aj_sk_event.event_data.dig("exception", "mechanism")).to eq("type" => "sidekiq", "handled" => false)
      expect(aj_sk_event.event_data.dig("contexts", "sidekiq")).to include(
        "jid" => "jid_wrapped_999",
        "class" => "InvoiceGenerationJob"
      )
      expect(aj_sk_event.event_data.dig("contexts", "active_job")).to include(
        "job_class" => "InvoiceGenerationJob"
      )

      # Lifecycle hooks flush cleanly
      expect(Sentrace).to receive(:flush).with(timeout: 2.0).twice
      lifecycle_events[:quiet].each(&:call)
      lifecycle_events[:shutdown].each(&:call)
    end
  end
end
