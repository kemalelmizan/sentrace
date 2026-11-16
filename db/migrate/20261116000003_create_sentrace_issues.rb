class CreateSentraceIssues < ActiveRecord::Migration[6.1]
  def change
    create_table :sentrace_issues do |t|
      t.references :project, null: false, index: false, foreign_key: { to_table: :sentrace_projects, on_delete: :cascade }
      t.string :fingerprint, limit: 64, null: false
      t.integer :status, limit: 2, null: false, default: 0
      t.integer :level, limit: 2, null: false
      t.string :exception_type, limit: 255
      t.string :message, limit: 1024
      t.column :first_seen_at, :timestamptz, null: false
      t.column :last_seen_at, :timestamptz, null: false
      t.bigint :event_count, null: false, default: 0
      t.column :created_at, :timestamptz, null: false
      t.column :updated_at, :timestamptz, null: false
    end

    add_index :sentrace_issues, [ :project_id, :fingerprint ],
      unique: true,
      name: "index_sentrace_issues_on_project_fingerprint"

    add_index :sentrace_issues, [ :project_id, :status, :last_seen_at ],
      order: { last_seen_at: :desc },
      name: "index_sentrace_issues_on_project_status_last_seen"
  end
end
