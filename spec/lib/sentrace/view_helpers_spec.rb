require "rails_helper"

RSpec.describe Sentrace::ViewHelpers do
  let(:helper_host_class) do
    Class.new do
      include Sentrace::ViewHelpers

      attr_accessor :request

      def initialize(request: nil)
        @request = request
      end
    end
  end

  after { Sentrace.reset_configuration! }

  it "renders HTML-escaped sentrace-* meta tags, strips DSN secrets, and includes request.request_id" do
    Sentrace.configure do |config|
      config.frontend_dsn = "https://pub123:supersecret@app.example.com/sentrace/7"
      config.deployment_environment = "production"
      config.release = %(v1.2.0-"quoted")
    end

    fake_request = Struct.new(:request_id, :base_url).new("req-abc-999", "https://app.example.com")
    rendered = helper_host_class.new(request: fake_request).sentrace_meta_tags

    expect(rendered).to be_html_safe
    expect(rendered).to include('<meta name="sentrace-dsn" content="https://pub123@app.example.com/sentrace/7">')
    expect(rendered).to include('<meta name="sentrace-environment" content="production">')
    expect(rendered).to include('<meta name="sentrace-release" content="v1.2.0-&quot;quoted&quot;">')
    expect(rendered).to include('<meta name="sentrace-request-id" content="req-abc-999">')
    expect(rendered).not_to include("supersecret")
  end

  it "auto-resolves same-origin public DSN from config.project_slug with zero SQL queries after warmup and invalidates on key rotation" do
    project, initial_key = Sentrace::Project.provision!(slug: "shop-web", name: "Shop Web")
    Sentrace.configure do |config|
      config.frontend_dsn = nil
      config.project_slug = "shop-web"
      config.deployment_environment = "production"
    end

    fake_request = Struct.new(:request_id, :base_url).new("req-auto-1", "https://shop.example.com")
    host = helper_host_class.new(request: fake_request)

    first_render = host.sentrace_meta_tags
    expect(first_render).to include(%(https://#{initial_key.public_key}@shop.example.com/sentrace/#{project.id}))

    sql_queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next if payload[:name] == "SCHEMA"

      sql_queries << payload[:sql]
    end

    begin
      second_render = host.sentrace_meta_tags
      spa_dsn = Sentrace.frontend_dsn(request: fake_request)
      explicit_base_dsn = Sentrace.resolve_frontend_dsn(base_url: "https://shop.example.com/sentrace")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(sql_queries).to eq([])
    expect(second_render).to include(%(https://#{initial_key.public_key}@shop.example.com/sentrace/#{project.id}))
    expect(spa_dsn).to eq("https://#{initial_key.public_key}@shop.example.com/sentrace/#{project.id}")
    expect(explicit_base_dsn).to eq("https://#{initial_key.public_key}@shop.example.com/sentrace/#{project.id}")

    # Explicit config.frontend_dsn takes precedence over project_slug when set
    Sentrace.configure do |config|
      config.project_slug = "shop-web"
      config.frontend_dsn = "https://cdn_override:sec@errors.cdn.example.com/sentrace/99"
    end
    expect(host.sentrace_meta_tags).to include("https://cdn_override@errors.cdn.example.com/sentrace/99")
    expect(Sentrace.frontend_dsn(request: fake_request)).to eq("https://cdn_override@errors.cdn.example.com/sentrace/99")

    # Reset frontend_dsn back to nil and verify rotate_key! invalidates the in-memory cache immediately
    Sentrace.configure do |config|
      config.frontend_dsn = nil
      config.project_slug = "shop-web"
    end
    expect(Sentrace.frontend_dsn(request: fake_request)).to include(initial_key.public_key)

    rotated_key = project.rotate_key!
    expect(rotated_key.public_key).not_to eq(initial_key.public_key)
    expect(Sentrace.frontend_dsn(request: fake_request)).to eq(
      "https://#{rotated_key.public_key}@shop.example.com/sentrace/#{project.id}"
    )

    # Revoking the remaining active key returns empty meta tags / nil without raising Sentrace::Error
    rotated_key.revoke!
    expect(host.sentrace_meta_tags).to eq("")
    expect(Sentrace.frontend_dsn(request: fake_request)).to be_nil
  end

  it "never raises in view rendering if database tables are unmigrated or unavailable" do
    Sentrace.configure do |config|
      config.frontend_dsn = nil
      config.project_slug = "unmigrated-app"
    end

    fake_request = Struct.new(:request_id, :base_url).new("req-db-down", "https://shop.example.com")
    allow(Sentrace::Project).to receive(:where).and_raise(ActiveRecord::StatementInvalid.new("PG::UndefinedTable: sentrace_projects"))

    expect(helper_host_class.new(request: fake_request).sentrace_meta_tags).to eq("")
    expect(Sentrace.frontend_dsn(request: fake_request)).to be_nil
  end

  it "resolves an explicit project slug dynamically using request.base_url and engine mount path when dsn is omitted" do
    project, key = Sentrace::Project.provision!(slug: "web-store", name: "Web Store")
    fake_request = Struct.new(:request_id, :base_url).new("req-dyn-1", "https://shop.example.com")

    rendered = helper_host_class.new(request: fake_request).sentrace_meta_tags(project: "web-store")

    expect(rendered).to include(%(https://#{key.public_key}@shop.example.com/sentrace/#{project.id}))
    expect(rendered).to include('content="req-dyn-1"')
  end

  it "registers lazily onto ActionView when loaded and returns empty html_safe output when unconfigured or disabled" do
    if defined?(ActionView::Base)
      expect(ActionView::Base.included_modules).to include(Sentrace::ViewHelpers)
    end

    empty = helper_host_class.new.sentrace_meta_tags
    expect(empty).to eq("")
    expect(empty).to be_html_safe

    Sentrace.configure do |config|
      config.enabled = false
      config.frontend_dsn = "https://pub123@app.example.com/sentrace/1"
    end
    expect(helper_host_class.new.sentrace_meta_tags).to eq("")
  end
end
