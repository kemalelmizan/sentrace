namespace :sentrace do
  desc "List all registered Sentrace projects and active public keys"
  task projects: :environment do
    Sentrace::ProjectManager.new.list
  end

  namespace :projects do
    desc "Create a Sentrace project and generate its initial DSN credential"
    task :create, [ :slug ] => :environment do |_task, args|
      Sentrace::ProjectManager.new.create(slug: args[:slug])
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      abort e.message
    end

    desc "Rotate the active DSN public key for a Sentrace project"
    task :rotate_key, [ :slug ] => :environment do |_task, args|
      Sentrace::ProjectManager.new.rotate_key(slug: args[:slug])
    rescue ArgumentError, Sentrace::ProjectManager::ProjectNotFoundError => e
      abort e.message
    end
  end
end
