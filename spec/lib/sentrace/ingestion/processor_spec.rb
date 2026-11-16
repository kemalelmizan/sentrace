require "rails_helper"

RSpec.describe Sentrace::Ingestion::Processor do
  let(:project) { create(:sentrace_project) }

  def sample_event_payload(event_id: SecureRandom.hex(16), timestamp: "2026-11-16T12:00:00Z", environment: "production", fingerprint: nil, type: "NoMethodError", value: "undefined method `foo'")
    payload = {
      "event_id" => event_id,
      "timestamp" => timestamp,
      "level" => "error",
      "platform" => "ruby",
      "environment" => environment,
      "release" => "v1.0.0",
      "exception" => {
        "values" => [
          {
            "type" => type,
            "value" => value,
            "stacktrace" => {
              "frames" => [
                { "filename" => "app/services/checkout.rb", "function" => "call", "lineno" => 19, "in_app" => true }
              ]
            }
          }
        ]
      }
    }
    payload["fingerprint"] = fingerprint if fingerprint
    payload
  end

  describe ".process_raw_envelope" do
    it "persists error events, groups matching fingerprints across environments, and ignores unsupported envelope items" do
      ev1 = sample_event_payload(
        event_id: "11111111111111111111111111111111",
        timestamp: "2026-11-16T12:00:00Z",
        environment: "staging"
      )
      ev2 = sample_event_payload(
        event_id: "22222222222222222222222222222222",
        timestamp: "2026-11-16T11:55:00Z",
        environment: "production"
      )

      raw = [
        { sent_at: "2026-11-16T12:00:01Z" }.to_json,
        { type: "event" }.to_json,
        ev1.to_json,
        { type: "transaction" }.to_json,
        { type: "transaction", spans: [] }.to_json,
        { type: "session" }.to_json,
        { sid: "abc" }.to_json,
        { type: "event" }.to_json,
        ev2.to_json
      ].join("\n") + "\n"

      result = described_class.process_raw_envelope(raw, project: project)

      expect(result.primary_event_id).to eq("11111111111111111111111111111111")
      expect(result.accepted_event_ids).to eq(%w[11111111111111111111111111111111 22222222222222222222222222222222])
      expect(result.discarded_count).to eq(2)

      expect(project.events.count).to eq(2)
      expect(project.issues.count).to eq(1)

      issue = project.issues.first
      expect(issue.event_count).to eq(2)
      expect(issue.status).to eq("unresolved")
      expect(issue.exception_type).to eq("NoMethodError")
      expect(issue.first_seen_at).to eq(Time.utc(2026, 11, 16, 11, 55, 0))
      expect(issue.last_seen_at).to eq(Time.utc(2026, 11, 16, 12, 0, 0))
    end

    it "is idempotent on duplicate (project_id, event_id) deliveries without incrementing event_count twice" do
      fixed_id = "0123456789abcdef0123456789abcdef"
      payload = sample_event_payload(event_id: fixed_id)

      first = described_class.ingest_event(payload, project: project)
      second = described_class.ingest_event(payload, project: project)

      expect(first.duplicate).to be(false)
      expect(second.duplicate).to be(true)
      expect(project.events.where(event_id: fixed_id).count).to eq(1)
      expect(project.issues.first.event_count).to eq(1)
    end

    it "reopens resolved issues to unresolved on regression while leaving ignored issues ignored" do
      resolved_payload = sample_event_payload(fingerprint: [ "fp-resolved" ])
      ignored_payload = sample_event_payload(fingerprint: [ "fp-ignored" ])

      res_one = described_class.ingest_event(resolved_payload, project: project)
      res_two = described_class.ingest_event(ignored_payload, project: project)

      resolved_issue = Sentrace::Issue.find(res_one.issue_id)
      ignored_issue = Sentrace::Issue.find(res_two.issue_id)
      resolved_issue.resolved!
      ignored_issue.ignored!

      described_class.ingest_event(
        sample_event_payload(fingerprint: [ "fp-resolved" ], timestamp: "2026-11-16T13:00:00Z"),
        project: project
      )
      described_class.ingest_event(
        sample_event_payload(fingerprint: [ "fp-ignored" ], timestamp: "2026-11-16T13:00:00Z"),
        project: project
      )

      expect(resolved_issue.reload.status).to eq("unresolved")
      expect(resolved_issue.event_count).to eq(2)

      expect(ignored_issue.reload.status).to eq("ignored")
      expect(ignored_issue.event_count).to eq(2)
    end
  end

  describe "multi-threaded concurrency", :concurrency do
    self.use_transactional_tests = false

    after do
      Sentrace::Event.delete_all
      Sentrace::Issue.delete_all
      Sentrace::ProjectKey.delete_all
      Sentrace::Project.delete_all
    end

    it "atomically creates exactly one issue with event_count == 10 when 10 threads ingest identical fingerprints simultaneously" do
      concurrent_project, = Sentrace::Project.provision!(slug: "concurrent-app")
      barrier = Queue.new
      ready = Queue.new

      threads = Array.new(10) do |idx|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            payload = sample_event_payload(
              event_id: format("%032x", idx + 1),
              fingerprint: [ "race-condition-check" ],
              timestamp: Time.utc(2026, 11, 16, 12, 0, idx).iso8601
            )
            ready << true
            barrier.pop
            described_class.ingest_event(payload, project: concurrent_project.id)
          end
        end
      end

      10.times { ready.pop }
      10.times { barrier << true }
      results = threads.map(&:value)

      expect(results.count { |r| !r.duplicate }).to eq(10)
      expect(concurrent_project.issues.count).to eq(1)

      issue = concurrent_project.issues.first
      expect(issue.event_count).to eq(10)
      expect(concurrent_project.events.where(issue_id: issue.id).count).to eq(10)
      expect(issue.first_seen_at).to eq(Time.utc(2026, 11, 16, 12, 0, 0))
      expect(issue.last_seen_at).to eq(Time.utc(2026, 11, 16, 12, 0, 9))
    end
  end
end
