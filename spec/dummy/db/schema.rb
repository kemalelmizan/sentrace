# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_20_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "sentrace_events", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "issue_id", null: false
    t.string "event_id", limit: 32, null: false
    t.timestamptz "occurred_at", null: false
    t.timestamptz "received_at", null: false
    t.string "environment", limit: 64
    t.string "release", limit: 128
    t.string "platform", limit: 32
    t.integer "level", limit: 2, null: false
    t.string "logger", limit: 128
    t.string "culprit", limit: 512
    t.jsonb "event_data", default: {}, null: false
    t.timestamptz "created_at", null: false
    t.index ["issue_id", "occurred_at"], name: "index_sentrace_events_on_issue_occurred_at", order: { occurred_at: :desc }
    t.index ["project_id", "event_id"], name: "index_sentrace_events_on_project_event_id", unique: true
    t.index ["project_id", "occurred_at"], name: "index_sentrace_events_on_project_occurred_at", order: { occurred_at: :desc }
  end

  create_table "sentrace_issues", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.string "fingerprint", limit: 64, null: false
    t.integer "status", limit: 2, default: 0, null: false
    t.integer "level", limit: 2, null: false
    t.string "exception_type", limit: 255
    t.string "message", limit: 1024
    t.timestamptz "first_seen_at", null: false
    t.timestamptz "last_seen_at", null: false
    t.bigint "event_count", default: 0, null: false
    t.timestamptz "created_at", null: false
    t.timestamptz "updated_at", null: false
    t.index ["project_id", "fingerprint"], name: "index_sentrace_issues_on_project_fingerprint", unique: true
    t.index ["project_id", "status", "last_seen_at"], name: "index_sentrace_issues_on_project_status_last_seen", order: { last_seen_at: :desc }
  end

  create_table "sentrace_mcp_tokens", force: :cascade do |t|
    t.string "name", limit: 120, null: false
    t.string "token_prefix", limit: 16, null: false
    t.string "token_digest", limit: 64, null: false
    t.boolean "active", default: true, null: false
    t.timestamptz "last_used_at"
    t.timestamptz "revoked_at"
    t.timestamptz "created_at", null: false
    t.timestamptz "expires_at"
    t.string "scopes", limit: 255, default: "read,write", null: false
    t.index ["token_digest"], name: "index_sentrace_mcp_tokens_on_token_digest", unique: true
  end

  create_table "sentrace_project_keys", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.string "public_key", limit: 64, null: false
    t.string "secret_digest", limit: 255
    t.boolean "active", default: true, null: false
    t.timestamptz "created_at", null: false
    t.timestamptz "revoked_at"
    t.index ["project_id"], name: "index_sentrace_project_keys_on_project_id"
    t.index ["public_key"], name: "index_sentrace_project_keys_on_public_key", unique: true
  end

  create_table "sentrace_projects", force: :cascade do |t|
    t.string "name", limit: 120, null: false
    t.string "slug", limit: 120, null: false
    t.timestamptz "created_at", null: false
    t.timestamptz "updated_at", null: false
    t.index ["slug"], name: "index_sentrace_projects_on_slug", unique: true
  end

  add_foreign_key "sentrace_events", "sentrace_issues", column: "issue_id", on_delete: :cascade
  add_foreign_key "sentrace_events", "sentrace_projects", column: "project_id", on_delete: :cascade
  add_foreign_key "sentrace_issues", "sentrace_projects", column: "project_id", on_delete: :cascade
  add_foreign_key "sentrace_project_keys", "sentrace_projects", column: "project_id", on_delete: :cascade
end
