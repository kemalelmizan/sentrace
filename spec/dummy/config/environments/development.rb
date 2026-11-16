Rails.application.configure do
  if config.respond_to?(:enable_reloading=)
    config.enable_reloading = true
  else
    config.cache_classes = false
  end

  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true if config.respond_to?(:server_timing=)
  config.active_support.deprecation = :log
end
