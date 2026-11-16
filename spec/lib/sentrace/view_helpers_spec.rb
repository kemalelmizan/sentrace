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

  it "resolves a project slug dynamically using request.base_url and engine mount path when dsn is omitted" do
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
