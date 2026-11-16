require "rails_helper"

RSpec.describe "Sentrace PostgreSQL schema and index strategy" do
  let(:connection) { ActiveRecord::Base.connection }

  it "creates only the five engine-owned sentrace_ tables" do
    sentrace_tables = connection.tables.select { |name| name.start_with?("sentrace_") }.sort
    expect(sentrace_tables).to eq(%w[
      sentrace_events
      sentrace_issues
      sentrace_mcp_tokens
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

    mcp_token_cols = connection.columns(:sentrace_mcp_tokens).index_by(&:name)
    expect(mcp_token_cols["token_digest"].sql_type).to eq("character varying(64)")
    expect(mcp_token_cols["created_at"].sql_type).to eq("timestamp with time zone")
    expect(mcp_token_cols["revoked_at"].sql_type).to eq("timestamp with time zone")
    expect(mcp_token_cols["last_used_at"].sql_type).to eq("timestamp with time zone")

    mcp_token_indexes = connection.indexes(:sentrace_mcp_tokens).index_by(&:name)
    expect(mcp_token_indexes.keys).to contain_exactly("index_sentrace_mcp_tokens_on_token_digest")
    expect(mcp_token_indexes["index_sentrace_mcp_tokens_on_token_digest"].unique).to be(true)
  end

  it "uses ActiveRecord::Migration[6.1] and t.column(..., :timestamptz) without PG 15+ SQL constructs" do
    migrations = Dir.glob(File.expand_path("../../db/migrate/*.rb", __dir__)).sort
    expect(migrations.size).to eq(5)

    migrations.each do |migration_file|
      source = File.read(migration_file)
      expect(source).to include("ActiveRecord::Migration[6.1]")
      expect(source).not_to include("t.timestamptz")
      expect(source).to include(":timestamptz")
    end

    ruby_sources = Dir.glob(File.expand_path("../../{app,lib}/**/*.rb", __dir__))
    ruby_sources.each do |file|
      content = File.read(file)
      expect(content).not_to match(/\bMERGE\s+INTO\b/i)
      expect(content).not_to match(/\bNULLS\s+NOT\s+DISTINCT\b/i)
    end
  end

  it "rolls all five engine migrations down and back up cleanly inside a transaction" do
    migrations_dir = File.expand_path("../../db/migrate", __dir__)
    migrations = Dir.glob(File.join(migrations_dir, "*.rb")).sort
    migrations.each { |file| require file }

    classes = [
      CreateSentraceProjects,
      CreateSentraceProjectKeys,
      CreateSentraceIssues,
      CreateSentraceEvents,
      CreateSentraceMcpTokens
    ]

    ActiveRecord::Migration.suppress_messages do
      classes.reverse_each { |klass| klass.migrate(:down) }
      classes.each { |klass| klass.migrate(:up) }
    end

    expect(connection.columns(:sentrace_events).index_by(&:name)["occurred_at"].sql_type)
      .to eq("timestamp with time zone")
  end
end
