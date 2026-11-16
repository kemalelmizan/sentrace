require "rails_helper"
require "rake"

RSpec.describe Sentrace::RetentionCleanupJob do
  include ActiveJob::TestHelper

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  before do
    Rake::Task["sentrace:retention:cleanup"].reenable
  end

  after { Sentrace.reset_configuration! }

  let!(:project) { Sentrace::Project.provision!(slug: "job-app").first }

  it "executes retention cleanup via ActiveJob without requiring Redis" do
    Sentrace::Ingestion::Processor.ingest_event(
      {
        "event_id" => SecureRandom.hex(16),
        "timestamp" => 40.days.ago.utc.iso8601,
        "level" => "error",
        "message" => "Expired job event"
      },
      project: project
    )
    expect(project.events.count).to eq(1)

    perform_enqueued_jobs do
      described_class.perform_later
    end

    expect(project.events.count).to eq(0)
  end

  it "executes retention cleanup via bin/rails sentrace:retention:cleanup" do
    Sentrace::Ingestion::Processor.ingest_event(
      {
        "event_id" => SecureRandom.hex(16),
        "timestamp" => 45.days.ago.utc.iso8601,
        "level" => "error",
        "message" => "Expired rake event"
      },
      project: project
    )

    output = StringIO.new
    original = $stdout
    begin
      $stdout = output
      Rake::Task["sentrace:retention:cleanup"].invoke
    ensure
      $stdout = original
    end

    expect(output.string).to include("Deleted expired events: 1")
    expect(output.string).to include("Deleted orphan issues:  1")
    expect(project.events.count).to eq(0)
    expect(project.issues.count).to eq(0)
  end
end
