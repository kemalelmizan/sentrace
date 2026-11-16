class CreateSentraceProjects < ActiveRecord::Migration[6.1]
  def change
    create_table :sentrace_projects do |t|
      t.string :name, limit: 120, null: false
      t.string :slug, limit: 120, null: false
      t.column :created_at, :timestamptz, null: false
      t.column :updated_at, :timestamptz, null: false
    end

    add_index :sentrace_projects, :slug, unique: true
  end
end
