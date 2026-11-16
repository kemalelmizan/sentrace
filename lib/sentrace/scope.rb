module Sentrace
  class Scope
    SCOPE_STACK_KEY = :sentrace_scope_stack

    attr_reader :tags, :user, :contexts, :extras, :breadcrumbs, :fingerprint, :level, :request, :transaction_name

    class << self
      def current
        stack.last
      end

      def with_scope
        return current unless block_given?

        current_stack = stack
        snapshot = current_stack.dup
        isolated = current_stack.last.deep_clone
        current_stack.push(isolated)
        yield(isolated)
      ensure
        Thread.current[SCOPE_STACK_KEY] = snapshot if snapshot
      end

      def configure_scope
        scope = current
        yield(scope) if block_given?
        scope
      end

      def clear!
        fresh = new
        Thread.current[SCOPE_STACK_KEY] = [ fresh ]
        fresh
      end

      private
        def stack
          existing = Thread.current[SCOPE_STACK_KEY]
          if existing.is_a?(Array) && existing.any?
            existing
          else
            Thread.current[SCOPE_STACK_KEY] = [ new ]
          end
        end
    end

    def initialize
      clear!
    end

    def clear!
      @tags = {}
      @user = nil
      @contexts = {}
      @extras = {}
      @breadcrumbs = []
      @fingerprint = nil
      @level = nil
      @request = nil
      @transaction_name = nil
      self
    end

    def clear_breadcrumbs!
      @breadcrumbs = []
      self
    end

    def set_tag(key, value)
      return self if key.nil?

      key_str = key.to_s.strip
      return self if key_str.empty?

      if value.nil?
        @tags.delete(key_str)
      else
        @tags[key_str] = value.to_s
      end
      self
    end

    def set_tags(tags_hash)
      return self unless tags_hash.is_a?(Hash)

      tags_hash.each { |k, v| set_tag(k, v) }
      self
    end

    def set_user(user_hash_or_nil)
      if user_hash_or_nil.nil? || (user_hash_or_nil.is_a?(Hash) && user_hash_or_nil.empty?)
        @user = nil
      elsif user_hash_or_nil.is_a?(Hash)
        @user = deep_copy(stringify_keys(user_hash_or_nil))
      end
      self
    end

    def set_context(name, context_hash)
      return self if name.nil?

      key = name.to_s.strip
      return self if key.empty?

      if context_hash.nil?
        @contexts.delete(key)
      elsif context_hash.is_a?(Hash)
        @contexts[key] = deep_copy(stringify_keys(context_hash))
      end
      self
    end

    def set_extra(key, value)
      return self if key.nil?

      key_str = key.to_s.strip
      return self if key_str.empty?

      @extras[key_str] = deep_copy(stringify_keys(value))
      self
    end

    def set_extras(extras_hash)
      return self unless extras_hash.is_a?(Hash)

      extras_hash.each { |k, v| set_extra(k, v) }
      self
    end

    def set_fingerprint(fingerprint_array)
      @fingerprint = fingerprint_array.is_a?(Array) ? fingerprint_array.map(&:to_s) : nil
      self
    end
    alias_method :fingerprint=, :set_fingerprint

    def set_level(new_level)
      @level = new_level&.to_s
      self
    end
    alias_method :level=, :set_level

    def set_request(request_hash)
      @request = request_hash.is_a?(Hash) ? deep_copy(stringify_keys(request_hash)) : nil
      self
    end
    alias_method :request=, :set_request

    def set_transaction_name(name)
      @transaction_name = name&.to_s
      self
    end
    alias_method :transaction_name=, :set_transaction_name

    def add_breadcrumb(crumb_or_hash = nil, max_breadcrumbs: Sentrace.configuration.max_breadcrumbs, **kwargs)
      crumb = Breadcrumb.from(crumb_or_hash, **kwargs)
      return self unless crumb

      limit = max_breadcrumbs.is_a?(Integer) && max_breadcrumbs.positive? ? max_breadcrumbs : 20
      @breadcrumbs << crumb.to_h
      overflow = @breadcrumbs.size - limit
      @breadcrumbs.shift(overflow) if overflow.positive?
      self
    end

    def deep_clone
      copy = self.class.allocate
      copy.instance_variable_set(:@tags, deep_copy(@tags))
      copy.instance_variable_set(:@user, deep_copy(@user))
      copy.instance_variable_set(:@contexts, deep_copy(@contexts))
      copy.instance_variable_set(:@extras, deep_copy(@extras))
      copy.instance_variable_set(:@breadcrumbs, deep_copy(@breadcrumbs))
      copy.instance_variable_set(:@fingerprint, deep_copy(@fingerprint))
      copy.instance_variable_set(:@level, @level&.dup)
      copy.instance_variable_set(:@request, deep_copy(@request))
      copy.instance_variable_set(:@transaction_name, @transaction_name&.dup)
      copy
    end

    private
      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify_keys(v) }
        when Array
          value.map { |item| stringify_keys(item) }
        else
          value
        end
      end

      def deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[deep_copy(k)] = deep_copy(v) }
        when Array
          value.map { |item| deep_copy(item) }
        when String
          value.dup
        else
          value
        end
      end
  end
end
