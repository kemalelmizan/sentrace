Rails.application.configure do
  if config.respond_to?(:enable_reloading=)
    config.enable_reloading = false
  else
    config.cache_classes = true
  end

  config.eager_load = ENV["CI"].present?
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = Rails.gem_version >= Gem::Version.new("7.1") ? :rescuable : false
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
end
