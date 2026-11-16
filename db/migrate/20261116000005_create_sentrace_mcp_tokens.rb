class CreateSentraceMcpTokens < ActiveRecord::Migration[6.1]
  def change
    create_table :sentrace_mcp_tokens do |t|
      t.string :name, limit: 120, null: false
      t.string :token_prefix, limit: 16, null: false
      t.string :token_digest, limit: 64, null: false
      t.boolean :active, null: false, default: true
      t.column :last_used_at, :timestamptz
      t.column :revoked_at, :timestamptz
      t.column :created_at, :timestamptz, null: false
    end

    add_index :sentrace_mcp_tokens, :token_digest,
      unique: true,
      name: "index_sentrace_mcp_tokens_on_token_digest"
  end
end
