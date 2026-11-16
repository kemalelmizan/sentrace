require "rails_helper"

RSpec.describe Sentrace::Benchmark::StorageRunner do
  self.use_transactional_tests = false

  after do
    Sentrace.reset_configuration!
    Sentrace::Event.delete_all
    Sentrace::Issue.delete_all
    Sentrace::ProjectKey.delete_all
    Sentrace::Project.delete_all
  end

  it "measures repeatable PostgreSQL storage, index overhead, throughput, and SPEC.md §11 latency targets" do
    output = StringIO.new
    report = described_class.print_report(event_count: 100, batch_size: 40, io: output)

    expect(report["event_count"]).to eq(100)
    expect(report["distinct_issues"]).to eq(25)
    expect(report["db_bytes_before"]).to be > 0
    expect(report["db_bytes_after"]).to be >= report["db_bytes_before"]
    expect(report["avg_bytes_per_event"]).to be > 0
    expect(report["index_overhead_bytes"]).to be > 0
    expect(report["write_events_per_second"]).to be > 0
    expect(report["retention_deleted_events"]).to eq(100)
    expect(report["retention_delete_events_per_second"]).to be > 0

    # SPEC.md §11 performance targets
    expect(report["envelope_parse_ms"]).to be < 50.0
    expect(report["event_persist_avg_ms"]).to be < 100.0
    expect(report["issue_lookup_ms"]).to be < 100.0
    expect(report["event_retrieval_ms"]).to be < 100.0
    expect(report["mcp_list_issues_ms"]).to be < 500.0

    expect(output.string).to include("Avg PostgreSQL bytes / event:")
    expect(Sentrace::Project.count).to eq(0)
    expect(Sentrace::Event.count).to eq(0)
  end
end
