require "uri"

module Sentrace
  module FrontendDsnResolver
    MAX_CACHE_ENTRIES = 128

    @cache_mutex = Mutex.new
    @project_key_cache = {}

    class << self
      def resolve(base_url: nil, request: nil, project: nil, dsn: nil, config: Sentrace.configuration)
        return nil unless config&.enabled

        explicit_dsn = dsn.to_s.strip
        return Dsn.parse(explicit_dsn).without_secret.to_s unless explicit_dsn.empty?

        if blank_value?(project)
          configured_dsn = config.frontend_dsn.to_s.strip
          return Dsn.parse(configured_dsn).without_secret.to_s unless configured_dsn.empty?
        end

        target = blank_value?(project) ? (non_blank(config.project_slug) || non_blank(config.project_id)) : project
        return nil if blank_value?(target)

        effective_base_url = resolve_mounted_base_url(base_url: base_url, request: request, config: config)
        return nil unless effective_base_url

        tuple = resolve_project_key_tuple(target)
        return nil unless tuple

        project_id, public_key = tuple
        Dsn.build(base_url: effective_base_url, public_key: public_key, project_id: project_id).without_secret.to_s
      rescue Error, ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        nil
      end

      def clear_cache!
        @cache_mutex.synchronize { @project_key_cache.clear }
      end

      def detect_engine_mount_path
        return "/sentrace" unless defined?(Rails) && Rails.application

        mounted = Rails.application.routes.routes.find do |route|
          app = route.app
          target = app.respond_to?(:app) ? app.app : app
          target == Sentrace::Engine
        end
        return "" unless mounted

        mounted.path.spec.to_s.chomp("/")
      rescue StandardError
        "/sentrace"
      end

      private
        def resolve_project_key_tuple(target)
          cache_key = normalize_cache_key(target)
          return nil unless cache_key

          cached = @cache_mutex.synchronize { @project_key_cache[cache_key] }
          return cached if cached

          project_id =
            if target.is_a?(Project) && target.id
              target.id
            elsif cache_key.first == :id
              Project.where(id: cache_key.last).pick(:id)
            else
              Project.where(slug: cache_key.last).pick(:id)
            end
          return nil unless project_id

          public_key = ProjectKey.active.where(project_id: project_id).order(created_at: :desc, id: :desc).pick(:public_key)
          return nil if public_key.nil? || public_key.empty?

          tuple = [ project_id, public_key ].freeze
          @cache_mutex.synchronize do
            @project_key_cache.shift if @project_key_cache.size >= MAX_CACHE_ENTRIES && !@project_key_cache.key?(cache_key)
            @project_key_cache[cache_key] = tuple
          end
          tuple
        end

        def normalize_cache_key(target)
          if target.is_a?(Project)
            return target.id ? [ :id, target.id ] : [ :slug, target.slug.to_s.strip.downcase ]
          end

          if target.is_a?(Integer)
            return target.positive? ? [ :id, target ] : nil
          end

          str = target.to_s.strip
          return nil if str.empty?

          if str.match?(/\A[1-9]\d*\z/)
            [ :id, Integer(str, 10) ]
          else
            [ :slug, str.downcase ]
          end
        end

        def resolve_mounted_base_url(base_url:, request:, config: Sentrace.configuration)
          raw_base = non_blank(base_url) ||
            non_blank(config&.public_base_url) ||
            (request.respond_to?(:base_url) ? non_blank(request.base_url) : nil)
          return nil unless raw_base

          uri = URI.parse(raw_base.to_s.strip)
          return nil unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
          return nil if uri.userinfo || uri.query || uri.fragment

          clean_base = uri.to_s.chomp("/")
          if uri.path.nil? || uri.path.empty? || uri.path == "/"
            mount_path = detect_engine_mount_path
            "#{clean_base}#{mount_path}"
          else
            clean_base
          end
        rescue URI::InvalidURIError
          nil
        end

        def non_blank(value)
          return nil if value.nil?

          str = value.to_s.strip
          str.empty? ? nil : value
        end

        def blank_value?(value)
          value.nil? || value.to_s.strip.empty?
        end
    end
  end
end
