require "rails_helper"

RSpec.describe Sentrace::Event, type: :model do
  it "stores structured frames, breadcrumbs, tags, and contexts in jsonb event_data" do
    event = create(:sentrace_event)
    reloaded = described_class.find(event.id)

    expect(reloaded.event_data.dig("exception", "type")).to eq("ActiveRecord::RecordNotFound")
    expect(reloaded.event_data.dig("tags", "component")).to eq("checkout")
    expect(reloaded).to be_level_error
    expect(reloaded.level_before_type_cast).to eq(40)
  end

  it "normalizes UUID-style event IDs and enforces uniqueness on (project_id, event_id)" do
    issue = create(:sentrace_issue)
    raw_uuid = "01234567-89AB-CDEF-0123-456789ABCDEF"
    created = create(:sentrace_event, project: issue.project, issue: issue, event_id: raw_uuid)

    expect(created.event_id).to eq("0123456789abcdef0123456789abcdef")

    duplicate = build(
      :sentrace_event,
      project: issue.project,
      issue: issue,
      event_id: "0123456789abcdef0123456789abcdef"
    )
    expect(duplicate).not_to be_valid

    expect {
      duplicate.save!(validate: false)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
