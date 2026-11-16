require "rails_helper"

RSpec.describe Sentrace::Issue, type: :model do
  it "enforces uniqueness of fingerprint within a project while allowing same fingerprint across projects" do
    project_one = create(:sentrace_project)
    project_two = create(:sentrace_project)

    create(:sentrace_issue, project: project_one, fingerprint: "abc123fingerprint")

    dup = build(:sentrace_issue, project: project_one, fingerprint: "abc123fingerprint")
    expect(dup).not_to be_valid

    expect {
      dup.save!(validate: false)
    }.to raise_error(ActiveRecord::RecordNotUnique)

    other_project_issue = create(:sentrace_issue, project: project_two, fingerprint: "abc123fingerprint")
    expect(other_project_issue).to be_persisted
  end

  it "transitions cleanly across unresolved, resolved, and ignored smallint statuses" do
    issue = create(:sentrace_issue)
    expect(issue).to be_unresolved
    expect(issue.status_before_type_cast).to eq(0)

    issue.resolved!
    expect(issue.reload).to be_resolved
    expect(issue.status_before_type_cast).to eq(1)

    issue.ignored!
    expect(issue.reload).to be_ignored
    expect(issue.status_before_type_cast).to eq(2)

    bad = build(:sentrace_issue, status: :archived)
    expect(bad).not_to be_valid
  end
end
