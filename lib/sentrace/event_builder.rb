require "securerandom"
require "time"

module Sentrace
  class EventBuilder
    SDK_NAME = "sentrace.ruby"
    MAX_CAUSE_DEPTH = 5
    BACKTRACE_LINE_REGEX = /\A(?<file>.+?):(?<line>\d+)(?::in [`'](?<fn>.+)'|:in (?<fn2>.+))?\z/

    class << self
      def build_exception_event(exception, scope:, config: Sentrace.configuration, **options)
        new(config: config).build_exception_event(exception, scope: scope, **options)
      end

      def build_message_event(message, scope:, level: :info, config: Sentrace.configuration, **options)
        new(config: config).build_message_event(message, scope: scope, level: level, **options)
      end

      def any_in_app_frame?(exception, config: Sentrace.configuration)
        return false unless exception.is_a?(Exception)

        new(config: config).any_in_app_frame?(exception)
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
        when Array
          value.map { |item| deep_stringify(item) }
        when Symbol
          value.to_s
        else
          value
        end
      end
    end

    def initialize(config: Sentrace.configuration)
      @config = config
    end

    def build_exception_event(exception, scope:, **options)
      handled = options.key?(:handled) ? (options[:handled] != false) : true
      mechanism_type = (options[:mechanism_type] || "generic").to_s
      level = (options[:level] || scope.level || (handled ? "error" : "error")).to_s

      values = extract_exception_chain(exception, handled: handled, mechanism_type: mechanism_type)

      raw_event = base_event(level: level, scope: scope, options: options)
      raw_event["exception"] = { "values" => values }
      apply_scope_and_options!(raw_event, scope: scope, options: options)
      raw_event
    end

    def build_message_event(message, scope:, level: :info, **options)
      resolved_level = (options[:level] || level || scope.level || :info).to_s
      raw_event = base_event(level: resolved_level, scope: scope, options: options)
      raw_event["message"] = message.to_s
      apply_scope_and_options!(raw_event, scope: scope, options: options)
      raw_event
    end

    def any_in_app_frame?(exception)
      extract_frames(exception).any? { |frame| frame["in_app"] == true }
    end

    private
      def base_event(level:, scope:, options:)
        event = {
          "event_id" => SecureRandom.hex(16),
          "timestamp" => Time.now.utc.iso8601(3),
          "platform" => "ruby",
          "level" => level,
          "environment" => (options[:environment] || @config.deployment_environment).to_s,
          "sdk" => {
            "name" => SDK_NAME,
            "version" => Sentrace::VERSION
          }
        }

        release = options.key?(:release) ? options[:release] : @config.release
        event["release"] = release.to_s if release && !release.to_s.empty?

        logger = options[:logger]
        event["logger"] = logger.to_s if logger && !logger.to_s.empty?

        culprit = options[:culprit] || scope.transaction_name
        event["transaction"] = culprit.to_s if culprit && !culprit.to_s.empty?

        event
      end

      def apply_scope_and_options!(raw_event, scope:, options:)
        merged_tags = scope.tags.dup
        if options[:tags].is_a?(Hash)
          options[:tags].each do |k, v|
            next if k.nil?
            v.nil? ? merged_tags.delete(k.to_s) : (merged_tags[k.to_s] = v.to_s)
          end
        end
        raw_event["tags"] = merged_tags unless merged_tags.empty?

        user =
          if options.key?(:user)
            options[:user].is_a?(Hash) ? self.class.deep_stringify(options[:user]) : nil
          else
            scope.user
          end
        raw_event["user"] = user if user.is_a?(Hash) && !user.empty?

        contexts = {
          "runtime" => {
            "name" => RUBY_ENGINE,
            "version" => RUBY_VERSION
          }
        }
        scope.contexts.each { |k, v| contexts[k.to_s] = self.class.deep_stringify(v) if v.is_a?(Hash) }
        if options[:contexts].is_a?(Hash)
          options[:contexts].each do |k, v|
            if v.nil?
              contexts.delete(k.to_s)
            elsif v.is_a?(Hash)
              contexts[k.to_s] = self.class.deep_stringify(v)
            end
          end
        end
        raw_event["contexts"] = contexts unless contexts.empty?

        extras = scope.extras.dup
        opt_extra = options[:extra] || options[:extras]
        if opt_extra.is_a?(Hash)
          opt_extra.each { |k, v| extras[k.to_s] = self.class.deep_stringify(v) unless k.nil? }
        end
        raw_event["extra"] = extras unless extras.empty?

        crumbs = scope.breadcrumbs.last(@config.max_breadcrumbs)
        raw_event["breadcrumbs"] = { "values" => crumbs } unless crumbs.empty?

        fp = options.key?(:fingerprint) ? options[:fingerprint] : scope.fingerprint
        raw_event["fingerprint"] = fp.map(&:to_s) if fp.is_a?(Array) && !fp.empty?

        req = options[:request].is_a?(Hash) ? self.class.deep_stringify(options[:request]) : scope.request
        raw_event["request"] = req if req.is_a?(Hash) && !req.empty?
      end

      def extract_exception_chain(exception, handled:, mechanism_type:)
        chain = []
        seen = {}
        current = exception

        while current.is_a?(Exception) && chain.size < MAX_CAUSE_DEPTH && !seen[current.object_id]
          seen[current.object_id] = true
          chain << current
          current = current.cause
        end

        ordered = chain.reverse
        ordered.each_with_index.map do |exc, idx|
          entry = {
            "type" => exc.class.name || "Exception",
            "value" => exc.message.to_s,
            "stacktrace" => {
              "frames" => extract_frames(exc)
            }
          }
          if idx == ordered.size - 1
            entry["mechanism"] = {
              "type" => mechanism_type,
              "handled" => handled
            }
          end
          entry
        end
      end

      def extract_frames(exception)
        max_frames = [ @config.max_stack_frames.to_i, 1 ].max
        app_root = resolve_app_root
        raw_backtrace = exception.backtrace

        if use_backtrace_locations?(exception, raw_backtrace)
          locations = exception.backtrace_locations.first(max_frames)
          locations.reverse.map do |loc|
            raw_path = (loc.absolute_path || loc.path).to_s
            filename, in_app = classify_path(raw_path, app_root)
            {
              "filename" => filename,
              "function" => loc.label.to_s,
              "lineno" => loc.lineno,
              "in_app" => in_app
            }
          end
        elsif raw_backtrace.is_a?(Array) && raw_backtrace.any?
          lines = raw_backtrace.first(max_frames)
          lines.reverse.filter_map do |line|
            parse_backtrace_line(line.to_s, app_root)
          end
        else
          []
        end
      end

      def use_backtrace_locations?(exception, raw_backtrace)
        return false unless exception.respond_to?(:backtrace_locations)

        locs = exception.backtrace_locations
        return false unless locs.is_a?(Array) && locs.any? && raw_backtrace.is_a?(Array)

        locs.size == raw_backtrace.size && locs.first.to_s == raw_backtrace.first
      end

      def parse_backtrace_line(line, app_root)
        match = BACKTRACE_LINE_REGEX.match(line)
        return nil unless match

        filename, in_app = classify_path(match[:file], app_root)
        fn = match[:fn] || match[:fn2]
        frame = {
          "filename" => filename,
          "lineno" => match[:line].to_i,
          "in_app" => in_app
        }
        frame["function"] = fn if fn && !fn.empty?
        frame
      end

      def classify_path(raw_path, app_root)
        return [ raw_path, false ] if raw_path.empty?

        if app_root && raw_path.start_with?("#{app_root}/")
          rel = raw_path.delete_prefix("#{app_root}/")
          vendored = rel.start_with?("vendor/", "bundle/", ".bundle/") || gem_path?(raw_path)
          [ rel, !vendored ]
        else
          [ raw_path, false ]
        end
      end

      def gem_path?(raw_path)
        return false unless defined?(Gem) && Gem.respond_to?(:path)

        Gem.path.any? { |gp| !gp.to_s.empty? && raw_path.start_with?("#{gp}/") }
      end

      def resolve_app_root
        return nil unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

        Rails.root.to_s
      end
  end
end
