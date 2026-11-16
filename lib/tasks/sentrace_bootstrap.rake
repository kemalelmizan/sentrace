namespace :sentrace do
  desc "Idempotently bootstrap Sentrace project and MCP token credentials from environment variables"
  task bootstrap: :environment do
    Sentrace::Bootstrapper.new.run
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message
  end
end
