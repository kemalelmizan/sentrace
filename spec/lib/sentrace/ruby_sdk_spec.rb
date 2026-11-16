require "rails_helper"

RSpec.describe "Sentrace Native Ruby SDK" do
  let!(:project) { Sentrace::Project.ensure!(slug: "monolith", name: "Monolith").first }

  before do
    Sentrace.clear_scope!
    Sentrace.configure do |config|
      config.project_slug = project.slug
      config.capture_dispatch = :inline
      config.release = "2026.11.16"
    end
  end

  after do
    Sentrace.clear_scope!
    Sentrace.reset_configuration!
  end

  describe "Sentrace::Breadcrumb and Sentrace.add_breadcrumb" do
    it "supports Breadcrumb instances, hashes, kwargs, and Sentry::Breadcrumb-like structs with max_breadcrumbs ring buffer" do
      Sentrace.configure do |config|
        config.project_slug = project.slug
        config.capture_dispatch = :inline
        config.max_breadcrumbs = 3
      end

      legacy_struct = Struct.new(:category, :message, :level, :type, :data, :timestamp, keyword_init: true)

      Sentrace.add_breadcrumb(Sentrace::Breadcrumb.new(category: "boot", message: "dropped-1"))
      Sentrace.add_breadcrumb({ category: "cache", message: "dropped-2", level: "debug" })
      Sentrace.add_breadcrumb(category: "auth", message: "kept-3", data: { method: "sso" })
      Sentrace.add_breadcrumb(
        legacy_struct.new(category: "db", message: "kept-4", level: "info", type: "query", data: { rows: 1 })
      )
      Sentrace.add_breadcrumb(Sentrace::Breadcrumb.new(category: "http", message: "kept-5", level: "warning"))

      event_id = Sentrace.capture_message("Breadcrumb check", level: :warning)
      expect(event_id).to match(/\A[0-9a-f]{32}\z/)

      stored = Sentrace::Event.find_by!(project_id: project.id, event_id: event_id)
      crumbs = stored.event_data["breadcrumbs"]
      expect(crumbs.map { |c| c["message"] }).to eq(%w[kept-3 kept-4 kept-5])
      expect(crumbs.first["data"]).to eq("method" => "sso")
      expect(crumbs[1]["type"]).to eq("query")
    end
  end

  describe "Scope isolation across with_scope, threads, and fibers" do
    it "merges global and nested with_scope attributes without leaking across scopes or threads" do
      Sentrace.set_tag("service", "billing")
      Sentrace.set_tags(region: "ap-southeast-1")
      Sentrace.set_user(id: 42, email: "alice@example.com")
      Sentrace.set_context("order", { currency: "USD", items: 3 })
      Sentrace.set_extra("attempt", 1)
      Sentrace.set_extras(gateway: "stripe")

      other_thread_tag = nil
      Thread.new do
        Sentrace.set_tag("service", "fulfillment")
        other_thread_tag = Sentrace.current_scope.tags["service"]
      end.join
      expect(other_thread_tag).to eq("fulfillment")
      expect(Sentrace.current_scope.tags["service"]).to eq("billing")

      fiber_tag = Fiber.new do
        Sentrace.set_tag("service", "fiber-worker")
        Sentrace.current_scope.tags["service"]
      end.resume
      expect(fiber_tag).to eq("fiber-worker")
      expect(Sentrace.current_scope.tags["service"]).to eq("billing")

      scoped_event_id = Sentrace.with_scope do |scope|
        scope.set_tag("step", "capture_payment")
        scope.add_breadcrumb(category: "payment", message: "charging card")
        Sentrace.capture_message("Scoped warning", level: :warning)
      end

      outer_event_id = Sentrace.capture_message("Outer info", level: :info)

      scoped_event = Sentrace::Event.find_by!(project_id: project.id, event_id: scoped_event_id)
      outer_event = Sentrace::Event.find_by!(project_id: project.id, event_id: outer_event_id)

      expect(scoped_event.event_data["tags"]).to include(
        "service" => "billing",
        "region" => "ap-southeast-1",
        "step" => "capture_payment"
      )
      expect(scoped_event.event_data.dig("user", "id_hash")).to be_present
      expect(scoped_event.event_data.dig("contexts", "order")).to eq("currency" => "USD", "items" => 3)
      expect(scoped_event.event_data.dig("contexts", "extra")).to include("attempt" => 1, "gateway" => "stripe")
      expect(scoped_event.event_data["breadcrumbs"].map { |c| c["message"] }).to eq([ "charging card" ])

      expect(outer_event.event_data["tags"]).to include("service" => "billing")
      expect(outer_event.event_data["tags"]).not_to have_key("step")
      expect(outer_event.event_data["breadcrumbs"]).to eq([])
    end
  end

  describe "Sentrace.capture_exception and filtering hooks" do
    def raise_chained_failure
      begin
        raise ArgumentError, "invalid tax rate"
      rescue ArgumentError
        raise RuntimeError, "checkout calculation failed"
      end
    end

    it "captures chained exceptions with in_app frames, custom options, and explicit capture of excluded_exceptions" do
      chained_error =
        begin
          raise_chained_failure
        rescue RuntimeError => e
          e.set_backtrace([
            "#{Rails.root}/app/services/checkout_service.rb:42:in `charge!'",
            "#{Rails.root}/vendor/bundle/ruby/3.3.0/gems/rack-2.2.9/lib/rack/builder.rb:10:in `call'"
          ])
          e
        end

      event_id = Sentrace.capture_exception(
        chained_error,
        level: :fatal,
        tags: { flow: "checkout" },
        contexts: { cart: { total_cents: 9900 } },
        extra: { coupon_applied: true },
        user: { id: "usr_99" },
        fingerprint: [ "checkout-tax-failure" ],
        handled: true
      )

      expect(event_id).to match(/\A[0-9a-f]{32}\z/)
      event = Sentrace::Event.find_by!(project_id: project.id, event_id: event_id)
      expect(event.level).to eq("fatal")
      expect(event.platform).to eq("ruby")
      expect(event.release).to eq("2026.11.16")
      expect(event.environment).to eq("test")
      expect(event.issue.exception_type).to eq("RuntimeError")
      expect(event.issue.message).to eq("checkout calculation failed")

      exc = event.event_data["exception"]
      expect(exc["type"]).to eq("RuntimeError")
      expect(exc["mechanism"]).to eq("type" => "generic", "handled" => true)
      expect(exc["frames"].size).to eq(2)
      expect(exc["frames"].first).to include(
        "filename" => "vendor/bundle/ruby/3.3.0/gems/rack-2.2.9/lib/rack/builder.rb",
        "in_app" => false
      )
      expect(exc["frames"].last).to include(
        "filename" => "app/services/checkout_service.rb",
        "function" => "charge!",
        "lineno" => 42,
        "in_app" => true
      )
      expect(event.event_data["tags"]).to include("flow" => "checkout")
      expect(event.event_data.dig("contexts", "cart")).to eq("total_cents" => 9900)
      expect(event.event_data.dig("contexts", "extra")).to include("coupon_applied" => true)
      expect(event.event_data.dig("user", "id_hash")).to be_present

      # Explicit capture_exception MUST still capture classes listed in excluded_exceptions
      routing_error = ActionController::RoutingError.new("No route matches [GET] /legacy")
      routing_error.set_backtrace([ "#{Rails.root}/app/controllers/orders_controller.rb:12:in `show'" ])
      routing_event_id = Sentrace.capture_exception(routing_error)
      expect(routing_event_id).to match(/\A[0-9a-f]{32}\z/)
      expect(Sentrace::Event.exists?(project_id: project.id, event_id: routing_event_id)).to be(true)
    end

    it "honors enabled, target project presence, sample_rate, and before_send mutation/dropping" do
      observed_hints = []
      Sentrace.configure do |config|
        config.project_slug = project.slug
        config.capture_dispatch = :inline
        config.before_send = lambda do |raw_event, hint|
          observed_hints << hint
          next nil if raw_event["message"] == "drop-this"

          raw_event["tags"] = (raw_event["tags"] || {}).merge("before_send" => "mutated")
          raw_event
        end
      end

      expect(Sentrace.capture_message("drop-this")).to be_nil
      kept_id = Sentrace.capture_message("keep-this", level: :info)
      expect(kept_id).to match(/\A[0-9a-f]{32}\z/)
      expect(observed_hints.size).to eq(2)

      kept_event = Sentrace::Event.find_by!(project_id: project.id, event_id: kept_id)
      expect(kept_event.event_data.dig("tags", "before_send")).to eq("mutated")

      Sentrace.configure do |config|
        config.project_slug = project.slug
        config.capture_dispatch = :inline
        config.sample_rate = 0.0
      end
      expect(Sentrace.capture_message("unsampled")).to be_nil

      Sentrace.configure do |config|
        config.project_slug = nil
        config.project_id = nil
        config.capture_dispatch = :inline
      end
      expect(Sentrace.capture_message("no-target-project")).to be_nil

      Sentrace.configure do |config|
        config.enabled = false
        config.project_slug = project.slug
        config.capture_dispatch = :inline
      end
      expect(Sentrace.capture_message("disabled")).to be_nil
    end
  end

  describe "Safe breadcrumbs_logger subscribers (:active_support_logger and :http_logger)" do
    it "records controller, SQL, and Net::HTTP metadata breadcrumbs without SQL bind values, HTTP bodies, or internal Sentrace queries" do
      Sentrace.configure do |config|
        config.project_slug = project.slug
        config.capture_dispatch = :inline
        config.breadcrumbs_logger = %i[active_support_logger http_logger]
        config.allow_fields = %w[token_present]
      end

      ActiveSupport::Notifications.instrument(
        "process_action.action_controller",
        controller: "OrdersController",
        action: "create",
        method: "POST",
        path: "/orders?token=secret_tok&token_present=1",
        status: 201,
        params: { credit_card: "4111-1111-1111-1111" }
      ) { }

      # Internal Sentrace controller action MUST be ignored
      ActiveSupport::Notifications.instrument(
        "process_action.action_controller",
        controller: "Sentrace::IngestionController",
        action: "create",
        method: "POST",
        path: "/sentrace/api/1/envelope",
        status: 200
      ) { }

      ActiveSupport::Notifications.instrument(
        "sql.active_record",
        name: "User Load",
        sql: "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"email\" = 'secret@example.com' AND \"users\".\"id\" = $1",
        binds: [ "secret-bind-value" ],
        type_casted_binds: [ "secret-bind-value" ]
      ) { }

      # Internal sentrace_* table query MUST be ignored
      ActiveSupport::Notifications.instrument(
        "sql.active_record",
        name: "Sentrace::Event Exists?",
        sql: "SELECT 1 AS one FROM \"sentrace_events\" WHERE \"sentrace_events\".\"id\" = 1"
      ) { }

      # Outbound Net::HTTP call using a local TCPServer so zero external network is needed
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server_thread = Thread.new do
        sock = server.accept
        sock.gets("\r\n\r\n")
        sock.write("HTTP/1.1 202 Accepted\r\nContent-Length: 14\r\nConnection: close\r\n\r\n{\"secret\":123}")
        sock.close
      ensure
        server.close
      end

      req = Net::HTTP::Post.new("/v1/charge?api_key=sk_live_999&token_present=true&mode=test")
      req.body = "{\"card_number\":\"4111222233334444\"}"
      Net::HTTP.start("127.0.0.1", port) { |http| http.request(req) }
      server_thread.join

      event_id = Sentrace.capture_message("Verify breadcrumb loggers")
      stored = Sentrace::Event.find_by!(project_id: project.id, event_id: event_id)
      crumbs = stored.event_data["breadcrumbs"]

      categories = crumbs.map { |c| c["category"] }
      expect(categories).to eq(%w[process_action.action_controller sql.active_record net.http])

      ctrl_crumb = crumbs[0]
      expect(ctrl_crumb["message"]).to eq("OrdersController#create")
      expect(ctrl_crumb.dig("data", "path")).to include("token=%5BREDACTED%5D")
      expect(ctrl_crumb.dig("data", "path")).to include("token_present=1")
      expect(JSON.generate(ctrl_crumb)).not_to include("4111-1111-1111-1111")

      sql_crumb = crumbs[1]
      expect(sql_crumb["message"]).to eq("User Load")
      expect(sql_crumb.dig("data", "statement")).to include("'?'")
      expect(JSON.generate(sql_crumb)).not_to include("secret@example.com")
      expect(JSON.generate(sql_crumb)).not_to include("secret-bind-value")

      http_crumb = crumbs[2]
      expect(http_crumb.dig("data", "method")).to eq("POST")
      expect(http_crumb.dig("data", "status_code")).to eq(202)
      expect(http_crumb.dig("data", "url")).to include("api_key=%5BREDACTED%5D")
      expect(http_crumb.dig("data", "url")).to include("token_present=true")
      expect(JSON.generate(http_crumb)).not_to include("4111222233334444")
      expect(JSON.generate(http_crumb)).not_to include("\"secret\":123")
    end
  end
end
