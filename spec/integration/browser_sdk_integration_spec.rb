require "rails_helper"
require "open3"
require "uri"

RSpec.describe "Browser SDK (`packages/sentrace`), `@sentry/browser` Wire Format, & Rails/MCP Integration", type: :request do
  ViewContextStub = Struct.new(:request) do
    include Sentrace::ViewHelpers
  end

  RequestStub = Struct.new(:base_url, :request_id)

  let!(:provisioned) { Sentrace::Project.provision!(slug: "storefront-web", name: "Storefront Web") }
  let(:project) { provisioned.first }
  let(:project_key) { provisioned.last }
  let(:sdk_esm_path) { Sentrace::Engine.root.join("packages/sentrace/dist/index.mjs").to_s }
  let(:mcp_server) { Sentrace::Mcp::Server.build }

  around do |example|
    Sentrace.reset_configuration!
    example.run
  ensure
    Sentrace.reset_configuration!
  end

  def mcp_rpc(method, params = {}, id: 1)
    raw = mcp_server.handle_json(
      JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params)
    )
    JSON.parse(raw)
  end

  def run_browser_sdk_capture(meta_html:)
    node_script = <<~JS
      import * as Sentrace from #{JSON.generate(sdk_esm_path)};

      const metaHtml = process.env.SENTRACE_META_HTML || "";
      const metaEntries = [];
      const tagRegex = /<meta\\s+name="([^"]+)"\\s+content="([^"]*)"\\s*\\/?>/g;
      let match;
      while ((match = tagRegex.exec(metaHtml)) !== null) {
        metaEntries.push({ name: match[1], content: match[2] });
      }

      const listeners = new Map();
      globalThis.document = {
        getElementsByTagName(tag) {
          return tag === "meta" ? metaEntries : [];
        },
        querySelector(selector) {
          const m = selector.match(/^meta\\[name="([^"]+)"\\]$/);
          if (!m) return null;
          const found = metaEntries.find((item) => item.name === m[1]);
          return found ? { getAttribute: (attr) => (attr === "content" ? found.content : null), content: found.content } : null;
        },
        addEventListener(type, fn) {
          const arr = listeners.get(type) || [];
          arr.push(fn);
          listeners.set(type, arr);
        },
        removeEventListener(type, fn) {
          const arr = listeners.get(type) || [];
          listeners.set(type, arr.filter((cb) => cb !== fn));
        }
      };

      const sentRequests = [];
      globalThis.window = {
        location: { href: "https://spa.example.com/checkout?session_token=secret-tok-123&step=payment" },
        navigator: { userAgent: "Mozilla/5.0 SentraceE2E/1.0" },
        addEventListener() {},
        removeEventListener() {}
      };

      globalThis.fetch = async (input, init = {}) => {
        const url = typeof input === "string" ? input : String(input.url);
        if (url.includes("/envelope")) {
          sentRequests.push({
            url,
            method: init.method || "POST",
            headers: init.headers || {},
            body: String(init.body || "")
          });
          return {
            status: 200,
            headers: { get: () => null }
          };
        }

        return {
          status: 500,
          headers: {
            get(name) {
              return String(name).toLowerCase() === "x-request-id" ? "req-e2e-corr-99" : null;
            }
          }
        };
      };

      Sentrace.initRails();
      Sentrace.setUser({ id: "usr_42", email: "buyer@example.com", ip_address: "203.0.113.9" });
      Sentrace.setExtra("cart_items", 3);

      await globalThis.fetch("https://spa.example.com/api/checkout?api_key=super-secret-key", { method: "POST" });

      const stimulusApp = { handleError() {} };
      Sentrace.registerStimulusErrorHandler(stimulusApp);

      const err = new TypeError("Cannot read properties of null (reading 'submitButton')");
      err.stack = [
        "TypeError: Cannot read properties of null (reading 'submitButton')",
        "    at submitCheckout (https://cdn.example.com/assets/checkout-a1b2c3d4.js:42:17)",
        "    at HTMLFormElement.<anonymous> (https://cdn.example.com/assets/application-99887766.js:18:9)"
      ].join("\\n");

      stimulusApp.handleError(err, "Error invoking action click->checkout#submitCheckout", {
        identifier: "checkout",
        action: "submitCheckout"
      });

      await Sentrace.flush(2000);
      process.stdout.write(JSON.stringify(sentRequests));
    JS

    stdout, stderr, status = Open3.capture3(
      { "SENTRACE_META_HTML" => meta_html },
      "node",
      "--input-type=module",
      "-e",
      node_script
    )
    expect(status.success?).to be(true), "Node SDK execution failed: #{stderr}"
    JSON.parse(stdout)
  end

  it "correlates Rails meta tags, browser SDK envelopes, @sentry/browser wire payloads, and backend errors via MCP" do
    dsn_with_secret = "http://#{project_key.public_key}:private_srv_secret@example.org/sentrace/#{project.id}"
    Sentrace.configure do |config|
      config.frontend_dsn = dsn_with_secret
      config.deployment_environment = "staging"
      config.release = "2026.11.16-web1"
      config.cors_allowed_origins = [ "https://spa.example.com" ]
    end

    view = ViewContextStub.new(RequestStub.new("http://example.org", "req-initial-page-01"))
    meta_html = view.sentrace_meta_tags
    expect(meta_html).to include("http://#{project_key.public_key}@example.org/sentrace/#{project.id}")
    expect(meta_html).not_to include("private_srv_secret")

    # 1. Verify CORS preflight for cross-origin browser transport
    options "/sentrace/api/#{project.id}/envelope", headers: {
      "Origin" => "https://spa.example.com",
      "Access-Control-Request-Method" => "POST"
    }
    expect(response).to have_http_status(:no_content)
    expect(response.headers["Access-Control-Allow-Origin"]).to eq("https://spa.example.com")

    # 2. Execute real `packages/sentrace` ESM bundle in Node against the rendered Rails `<meta>` tags
    captured_requests = run_browser_sdk_capture(meta_html: meta_html)
    expect(captured_requests.size).to eq(1)

    sdk_req = captured_requests.first
    parsed_uri = URI.parse(sdk_req["url"])
    request_target = "#{parsed_uri.path}?#{parsed_uri.query}"

    post request_target, params: sdk_req["body"], headers: {
      "Content-Type" => sdk_req.dig("headers", "Content-Type") || "text/plain;charset=UTF-8",
      "Origin" => "https://spa.example.com"
    }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Access-Control-Allow-Origin"]).to eq("https://spa.example.com")

    # 3. Ingest correlated Rails backend exception from the failed `/api/checkout` request (`X-Request-Id: req-e2e-corr-99`)
    Sentrace::Ingestion::Processor.ingest_event(
      {
        "event_id" => "11111111222222223333333344444444",
        "timestamp" => "2026-11-16T12:00:00Z",
        "platform" => "ruby",
        "level" => "error",
        "environment" => "staging",
        "release" => "2026.11.16-web1",
        "request" => {
          "url" => "https://spa.example.com/api/checkout",
          "method" => "POST",
          "headers" => { "X-Request-Id" => "req-e2e-corr-99" }
        },
        "exception" => {
          "values" => [
            {
              "type" => "ActiveRecord::RecordInvalid",
              "value" => "Validation failed: Payment method expired",
              "stacktrace" => {
                "frames" => [
                  { "filename" => "app/controllers/api/checkouts_controller.rb", "function" => "create", "lineno" => 31, "in_app" => true }
                ]
              }
            }
          ]
        }
      },
      project: project
    )

    # 4. Ingest an official `@sentry/browser` v8 wire-format envelope (no item `length`, different JS asset digest & origin,
    #    plus non-error `session`, `client_report`, and `replay_event` items that must be discarded)
    sentry_browser_event_id = "aaaabbbbccccddddeeeeffff00001111"
    sentry_browser_event = {
      event_id: sentry_browser_event_id,
      timestamp: 1_763_294_500.25,
      platform: "javascript",
      level: "error",
      environment: "staging",
      release: "2026.11.16-web2",
      sdk: { name: "sentry.javascript.browser", version: "8.40.0" },
      exception: {
        values: [
          {
            type: "TypeError",
            value: "Cannot read properties of null (reading 'submitButton')",
            stacktrace: {
              frames: [
                {
                  filename: "https://app.example.com/assets/application-11223344.js",
                  function: "HTMLFormElement.<anonymous>",
                  lineno: 18,
                  colno: 9,
                  in_app: true
                },
                {
                  filename: "https://app.example.com/assets/checkout-B9xK2pQ1.js",
                  function: "submitCheckout",
                  lineno: 42,
                  colno: 99,
                  in_app: true
                }
              ]
            }
          }
        ]
      },
      extra: { retry_attempt: 2 }
    }

    sentry_browser_envelope = [
      { event_id: sentry_browser_event_id, sent_at: "2026-11-16T12:01:40.250Z", dsn: "http://#{project_key.public_key}@example.org/sentrace/#{project.id}" }.to_json,
      { type: "event" }.to_json,
      sentry_browser_event.to_json,
      { type: "session" }.to_json,
      { sid: "sess_1", status: "exited" }.to_json,
      { type: "client_report" }.to_json,
      { timestamp: 1_763_294_500, discarded_events: [] }.to_json,
      { type: "replay_event" }.to_json,
      { segment_id: 0 }.to_json
    ].join("\n") + "\n"

    post "/sentrace/api/#{project.id}/envelope?sentry_version=7&sentry_key=#{project_key.public_key}&sentry_client=sentry.javascript.browser/8.40.0",
      params: sentry_browser_envelope,
      headers: { "Content-Type" => "text/plain;charset=UTF-8" }
    expect(response).to have_http_status(:ok)

    # Verify issue grouping across asset hashes (`checkout-a1b2c3d4.js` == `checkout-B9xK2pQ1.js`) and zero rows for non-error items
    expect(project.events.count).to eq(3)
    expect(project.issues.count).to eq(2)

    js_events = project.events.where(platform: "javascript").order(:created_at).to_a
    expect(js_events.size).to eq(2)
    expect(js_events.map(&:issue_id).uniq.size).to eq(1)

    first_js = js_events.first
    second_js = js_events.last
    expect(first_js.environment).to eq("staging")
    expect(first_js.release).to eq("2026.11.16-web1")
    expect(first_js.event_data.dig("tags", "request_id")).to eq("req-e2e-corr-99")
    expect(first_js.event_data.dig("tags", "stimulus.controller")).to eq("checkout")
    expect(first_js.event_data.dig("contexts", "extra", "cart_items")).to eq(3)
    expect(first_js.event_data.dig("exception", "frames").last["colno"]).to eq(17)
    expect(second_js.event_data.dig("exception", "frames").last["colno"]).to eq(99)
    expect(second_js.event_data.dig("contexts", "extra", "retry_attempt")).to eq(2)

    # Verify PII scrubbing on user + URL query tokens
    expect(first_js.event_data["user"].keys).to eq([ "id_hash" ])
    serialized_first = JSON.generate(first_js.event_data)
    expect(serialized_first).not_to include("buyer@example.com")
    expect(serialized_first).not_to include("203.0.113.9")
    expect(serialized_first).not_to include("secret-tok-123")
    expect(serialized_first).not_to include("super-secret-key")

    # 5. Verify MCP cross-stack correlation (`list_events(request_id: ...)` + `list_issues(platform: "javascript")`)
    corr_resp = mcp_rpc("tools/call", {
      name: "list_events",
      arguments: { project_id: project.id, request_id: "req-e2e-corr-99" }
    })
    expect(corr_resp.dig("result", "isError")).to be(false)
    corr_events = corr_resp.dig("result", "structuredContent", "events")
    expect(corr_events.size).to eq(2)
    expect(corr_events.map { |e| e["platform"] }).to contain_exactly("javascript", "ruby")
    expect(corr_events.map { |e| e["request_id"] }).to eq([ "req-e2e-corr-99", "req-e2e-corr-99" ])

    js_issues_resp = mcp_rpc("tools/call", {
      name: "list_issues",
      arguments: { project_id: project.id, platform: "javascript" }
    })
    expect(js_issues_resp.dig("result", "isError")).to be(false)
    js_issues = js_issues_resp.dig("result", "structuredContent", "issues")
    expect(js_issues.size).to eq(1)
    expect(js_issues.first["exception_type"]).to eq("TypeError")
    expect(js_issues.first["event_count"]).to eq(2)
  end
end
