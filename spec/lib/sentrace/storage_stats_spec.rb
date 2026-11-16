require "rails_helper"

RSpec.describe Sentrace::StorageStats do
  after { Sentrace.reset_configuration! }

  let!(:project) { Sentrace::Project.provision!(slug: "stats-app").first }
  let(:now) { Time.utc(2026, 11, 16, 12, 0, 0) }

  def ingest_at(ts, fingerprint: "fp-stats")
    Sentrace::Ingestion::Processor.ingest_event(
      {
        "event_id" => SecureRandom.hex(16),
        "timestamp" => ts.utc.iso8601,
        "level" => "error",
        "message" => "Stats event",
        "fingerprint" => [ fingerprint ]
      },
      project: project,
      received_at: ts
    )
  end

  it "computes event/issue counts, removed-by-retention counts, daily buckets, and PostgreSQL relation sizes without metric tables" do
    ingest_at(now - 45.days)
    ingest_at(now - 40.days)
    ingest_at(now - 2.days)
    ingest_at(now - 1.hour)

    Sentrace.configure { |c| c.retention_period = 30.days }
    Sentrace::Retention::Cleaner.run!(now: now)

    stats = described_class.collect(days: 30, now: now)

    expect(stats["total_events"]).to eq(2)
    expect(stats["total_issues"]).to eq(1)
    expect(stats["events_removed_by_retention"]).to eq(2)
    expect(stats["oldest_retained_event_at"]).to eq((now - 2.days).iso8601)
    expect(stats["newest_retained_event_at"]).to eq((now - 1.hour).iso8601)
    expect(stats["database_storage_bytes"]).to be > 0
    expect(stats["table_bytes"]).to be > 0
    expect(stats["index_bytes"]).to be > 0
    expect(stats["tables"].map { |t| t["table_name"] }).to eq(%w[
      sentrace_events
      sentrace_issues
      sentrace_mcp_tokens
      sentrace_project_keys
      sentrace_projects
    ])
    expect(stats["events_per_day"].sum { |d| d["count"] }).to eq(2)
  end
end
