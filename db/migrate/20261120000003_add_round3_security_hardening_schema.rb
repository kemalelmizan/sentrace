class AddRound3SecurityHardeningSchema < ActiveRecord::Migration[6.1]
  def up
    change_column_default :sentrace_mcp_tokens, :scopes, from: "read,write", to: "read"
    add_column :sentrace_mcp_tokens, :project_id, :bigint
    add_foreign_key :sentrace_mcp_tokens, :sentrace_projects, column: :project_id, on_delete: :cascade

    add_index :sentrace_events, :occurred_at, name: "index_sentrace_events_on_occurred_at"
    add_index :sentrace_issues, [ :last_seen_at, :id ],
      order: { last_seen_at: :desc, id: :desc },
      name: "index_sentrace_issues_on_last_seen_at_id"
  end

  def down
    remove_index :sentrace_issues, name: "index_sentrace_issues_on_last_seen_at_id"
    remove_index :sentrace_events, name: "index_sentrace_events_on_occurred_at"

    remove_foreign_key :sentrace_mcp_tokens, column: :project_id
    remove_column :sentrace_mcp_tokens, :project_id
    change_column_default :sentrace_mcp_tokens, :scopes, from: "read", to: "read,write"
  end
end
