class CreateSentraceEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :sentrace_events do |t|
      t.references :project, null: false, index: false, foreign_key: { to_table: :sentrace_projects, on_delete: :cascade }
      t.references :issue, null: false, index: false, foreign_key: { to_table: :sentrace_issues, on_delete: :cascade }
      t.column :event_id, "char(32)", null: false
      t.timestamptz :occurred_at, null: false
      t.timestamptz :received_at, null: false
      t.string :environment, limit: 64
      t.string :release, limit: 128
      t.string :platform, limit: 32
      t.integer :level, limit: 2, null: false
      t.string :logger, limit: 128
      t.string :culprit, limit: 512
      t.jsonb :event_data, null: false, default: {}
      t.timestamptz :created_at, null: false
    end

    add_index :sentrace_events, [ :project_id, :event_id ],
      unique: true,
      name: "index_sentrace_events_on_project_event_id"

    add_index :sentrace_events, [ :issue_id, :occurred_at ],
      order: { occurred_at: :desc },
      name: "index_sentrace_events_on_issue_occurred_at"

    add_index :sentrace_events, [ :project_id, :occurred_at ],
      order: { occurred_at: :desc },
      name: "index_sentrace_events_on_project_occurred_at"
  end
end
