require "rails_helper"

RSpec.describe "Sentrace PostgreSQL schema and index strategy" do
  let(:connection) { ActiveRecord::Base.connection }

  it "creates only the four engine-owned sentrace_ tables" do
    sentrace_tables = connection.tables.select { |name| name.start_with?("sentrace_") }.sort
    expect(sentrace_tables).to eq(%w[
      sentrace_events
      sentrace_issues
      sentrace_project_keys
      sentrace_projects
    ])
  end

  it "uses timestamptz, smallint, char(32), and jsonb types matching SPEC.md §5.3" do
    issue_cols = connection.columns(:sentrace_issues).index_by(&:name)
    expect(issue_cols["status"].sql_type).to eq("smallint")
    expect(issue_cols["level"].sql_type).to eq("smallint")
    expect(issue_cols["first_seen_at"].sql_type).to eq("timestamp with time zone")
    expect(issue_cols["last_seen_at"].sql_type).to eq("timestamp with time zone")

    event_cols = connection.columns(:sentrace_events).index_by(&:name)
    expect(event_cols["event_id"].sql_type).to eq("character(32)")
    expect(event_cols["level"].sql_type).to eq("smallint")
    expect(event_cols["event_data"].sql_type).to eq("jsonb")
    expect(event_cols["occurred_at"].sql_type).to eq("timestamp with time zone")
    expect(event_cols["received_at"].sql_type).to eq("timestamp with time zone")
    expect(event_cols).not_to have_key("updated_at")
  end

  it "creates the five targeted composite indexes with DESC ordering and zero GIN or duplicate FK indexes" do
    issue_indexes = connection.indexes(:sentrace_issues).index_by(&:name)
    expect(issue_indexes.keys).to contain_exactly(
      "index_sentrace_issues_on_project_fingerprint",
      "index_sentrace_issues_on_project_status_last_seen"
    )
    expect(issue_indexes["index_sentrace_issues_on_project_fingerprint"].unique).to be(true)
    expect(issue_indexes["index_sentrace_issues_on_project_status_last_seen"].orders).to eq("last_seen_at" => :desc)

    event_indexes = connection.indexes(:sentrace_events).index_by(&:name)
    expect(event_indexes.keys).to contain_exactly(
      "index_sentrace_events_on_project_event_id",
      "index_sentrace_events_on_issue_occurred_at",
      "index_sentrace_events_on_project_occurred_at"
    )
    expect(event_indexes["index_sentrace_events_on_project_event_id"].unique).to be(true)
    expect(event_indexes["index_sentrace_events_on_issue_occurred_at"].orders).to eq("occurred_at" => :desc)
    expect(event_indexes["index_sentrace_events_on_project_occurred_at"].orders).to eq("occurred_at" => :desc)
    expect(event_indexes.values.map(&:using)).to all(eq(:btree))
  end
end
