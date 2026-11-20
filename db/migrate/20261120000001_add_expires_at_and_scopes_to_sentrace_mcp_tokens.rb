class AddExpiresAtAndScopesToSentraceMcpTokens < ActiveRecord::Migration[6.1]
  def change
    add_column :sentrace_mcp_tokens, :expires_at, :timestamptz
    add_column :sentrace_mcp_tokens, :scopes, :string, limit: 255, null: false, default: "read,write"
  end
end
