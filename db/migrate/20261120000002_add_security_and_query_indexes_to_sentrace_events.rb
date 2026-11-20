class AddSecurityAndQueryIndexesToSentraceEvents < ActiveRecord::Migration[6.1]
  def change
    add_index :sentrace_events, :received_at,
      name: "index_sentrace_events_on_received_at"

    add_index :sentrace_events, [ :issue_id, :release ],
      where: "release IS NOT NULL",
      name: "index_sentrace_events_on_issue_release"

    add_index :sentrace_events, [ :issue_id, :platform ],
      where: "platform IS NOT NULL",
      name: "index_sentrace_events_on_issue_platform"

    add_index :sentrace_events,
      "(event_data -> 'tags' ->> 'request_id')",
      where: "(event_data -> 'tags' ->> 'request_id') IS NOT NULL",
      name: "index_sentrace_events_on_request_id"
  end
end
