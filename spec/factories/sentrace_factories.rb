require "securerandom"

FactoryBot.define do
  factory :sentrace_project, class: "Sentrace::Project" do
    sequence(:name) { |n| "Application #{n}" }
    sequence(:slug) { |n| "application-#{n}" }
  end

  factory :sentrace_project_key, class: "Sentrace::ProjectKey" do
    association :project, factory: :sentrace_project
    public_key { SecureRandom.hex(16) }
    active { true }
  end

  factory :sentrace_issue, class: "Sentrace::Issue" do
    association :project, factory: :sentrace_project
    sequence(:fingerprint) { |n| Digest::SHA256.hexdigest("fingerprint-#{n}") }
    status { :unresolved }
    level { :error }
    exception_type { "ActiveRecord::RecordNotFound" }
    message { "Couldn't find Order with ID=123" }
    first_seen_at { 5.minutes.ago }
    last_seen_at { Time.current }
    event_count { 1 }
  end

  factory :sentrace_event, class: "Sentrace::Event" do
    project { issue.project }
    association :issue, factory: :sentrace_issue
    event_id { SecureRandom.hex(16) }
    occurred_at { Time.current }
    received_at { Time.current }
    environment { "production" }
    release { "2026.11.16" }
    platform { "ruby" }
    level { :error }
    logger { "rails" }
    culprit { "OrdersController#show" }
    event_data do
      {
        "exception" => {
          "type" => "ActiveRecord::RecordNotFound",
          "value" => "Couldn't find Order with ID=123",
          "frames" => [
            { "filename" => "app/services/orders/find.rb", "function" => "call", "lineno" => 42, "in_app" => true }
          ]
        },
        "breadcrumbs" => [],
        "tags" => { "component" => "checkout" },
        "contexts" => { "runtime" => { "name" => "ruby", "version" => RUBY_VERSION } },
        "user" => { "id_hash" => Digest::SHA256.hexdigest("user-42") }
      }
    end
  end
end
