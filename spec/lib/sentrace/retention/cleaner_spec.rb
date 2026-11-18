require "rails_helper"

RSpec.describe Sentrace::Retention::Cleaner do
  after { Sentrace.reset_configuration! }

  let!(:project) { Sentrace::Project.provision!(slug: "retention-app").first }
  let(:now) { Time.utc(2026, 11, 16, 12, 0, 0) }

  def ingest_at(ts, fingerprint: "fp-shared", message: "Boom")
    Sentrace::Ingestion::Processor.ingest_event(
      {
        "event_id" => SecureRandom.hex(16),
        "timestamp" => ts.utc.iso8601,
        "level" => "error",
        "message" => message,
        "fingerprint" => [ fingerprint ]
      },
      project: project,
      received_at: ts
    )
  end

  it "deletes expired events across multiple bounded batches while preserving recent events and parent issues" do
    5.times { |idx| ingest_at(now - 45.days - idx.minutes, fingerprint: "fp-active") }
    ingest_at(now - 2.days, fingerprint: "fp-active")

    Sentrace.configure do |c|
      c.retention_period = 30.days
      c.orphan_issue_retention_period = 7.days
      c.retention_batch_size = 2
    end

    result = described_class.run!(now: now)

    expect(result.deleted_events_count).to eq(5)
    expect(result.event_batches).to eq(3)
    expect(result.deleted_orphan_issues_count).to eq(0)
    expect(project.events.count).to eq(1)
    expect(project.issues.count).to eq(1)
    expect(project.issues.first.event_count).to eq(6)
  end

  it "does not immediately delete an issue when its last event expires until orphan_issue_retention_period also elapses" do
    # Issue A: last event 31 days ago, but orphan_issue_retention_period is 40 days -> issue retained!
    ingest_at(now - 31.days, fingerprint: "fp-recent-orphan")
    # Issue B: last event 45 days ago -> event deleted AND issue older than 40-day orphan cutoff -> issue pruned!
    ingest_at(now - 45.days, fingerprint: "fp-aged-orphan")

    Sentrace.configure do |c|
      c.retention_period = 30.days
      c.orphan_issue_retention_period = 40.days
      c.retention_batch_size = 10
    end

    result = described_class.run!(now: now)

    expect(result.deleted_events_count).to eq(2)
    expect(result.deleted_orphan_issues_count).to eq(1)
    expect(result.event_batches).to eq(1)
    expect(result.issue_batches).to eq(1)
    expect(result.event_cutoff).to eq(now - 30.days)
    expect(result.orphan_issue_cutoff).to eq(now - 40.days)
    expect(project.events.count).to eq(0)

    remaining_issues = project.issues.to_a
    expect(remaining_issues.size).to eq(1)
    expect(remaining_issues.first.message).to eq("Boom")
    expect(remaining_issues.first.last_seen_at).to eq(now - 31.days)
  end
end
