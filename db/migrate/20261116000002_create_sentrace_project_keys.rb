class CreateSentraceProjectKeys < ActiveRecord::Migration[6.1]
  def change
    create_table :sentrace_project_keys do |t|
      t.references :project, null: false, foreign_key: { to_table: :sentrace_projects, on_delete: :cascade }
      t.string :public_key, limit: 64, null: false
      t.string :secret_digest, limit: 255
      t.boolean :active, null: false, default: true
      t.column :created_at, :timestamptz, null: false
      t.column :revoked_at, :timestamptz
    end

    add_index :sentrace_project_keys, :public_key, unique: true
  end
end
