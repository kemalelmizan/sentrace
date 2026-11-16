class CreateSentraceProjects < ActiveRecord::Migration[7.1]
  def change
    create_table :sentrace_projects do |t|
      t.string :name, limit: 120, null: false
      t.string :slug, limit: 120, null: false
      t.timestamptz :created_at, null: false
      t.timestamptz :updated_at, null: false
    end

    add_index :sentrace_projects, :slug, unique: true
  end
end
