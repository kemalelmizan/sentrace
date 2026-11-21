namespace :sentrace do
  desc "List all registered Sentrace projects and active public keys"
  task projects: :environment do
    Sentrace::ProjectManager.new.list
  end

  namespace :projects do
    desc "Create a Sentrace project and generate its initial DSN credential (pass SECRET=true for server-only secret DSN)"
    task :create, [ :slug ] => :environment do |_task, args|
      secret = ENV["SENTRACE_PROJECT_SECRET_KEY"]&.strip.presence
      generate_secret = ENV["SECRET"].to_s.casecmp("true").zero?
      Sentrace::ProjectManager.new.create(slug: args[:slug], secret: secret, generate_secret: generate_secret)
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      abort e.message
    end

    desc "Rotate the active DSN public key for a Sentrace project (pass SECRET=true for server-only secret DSN)"
    task :rotate_key, [ :slug ] => :environment do |_task, args|
      secret = ENV["SENTRACE_PROJECT_SECRET_KEY"]&.strip.presence
      generate_secret = ENV["SECRET"].to_s.casecmp("true").zero?
      Sentrace::ProjectManager.new.rotate_key(slug: args[:slug], secret: secret, generate_secret: generate_secret)
    rescue ArgumentError, Sentrace::ProjectManager::ProjectNotFoundError => e
      abort e.message
    end
  end
end
