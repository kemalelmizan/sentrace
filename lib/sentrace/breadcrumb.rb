require "time"

module Sentrace
  class Breadcrumb
    attr_accessor :category, :message, :level, :type, :data, :timestamp

    class << self
      def from(crumb_or_hash = nil, **kwargs)
        case crumb_or_hash
        when Breadcrumb
          return crumb_or_hash if kwargs.empty?

          merged = crumb_or_hash.to_h.merge(stringify_keys(kwargs))
          build_from_hash(merged)
        when Hash
          build_from_hash(stringify_keys(crumb_or_hash).merge(stringify_keys(kwargs)))
        when nil
          return nil if kwargs.empty?

          new(**kwargs)
        else
          if crumb_or_hash.respond_to?(:to_hash)
            build_from_hash(stringify_keys(crumb_or_hash.to_hash).merge(stringify_keys(kwargs)))
          elsif crumb_or_hash.respond_to?(:category) && crumb_or_hash.respond_to?(:message)
            new(
              category: kwargs.fetch(:category, crumb_or_hash.category),
              message: kwargs.fetch(:message, crumb_or_hash.message),
              level: kwargs.fetch(:level, crumb_or_hash.respond_to?(:level) ? crumb_or_hash.level : "info"),
              type: kwargs.fetch(:type, crumb_or_hash.respond_to?(:type) ? crumb_or_hash.type : "default"),
              data: kwargs.fetch(:data, crumb_or_hash.respond_to?(:data) ? crumb_or_hash.data : nil),
              timestamp: kwargs.fetch(:timestamp, crumb_or_hash.respond_to?(:timestamp) ? crumb_or_hash.timestamp : nil)
            )
          end
        end
      end

      private
        def build_from_hash(hash)
          new(
            category: hash["category"],
            message: hash["message"],
            level: hash.key?("level") ? hash["level"] : "info",
            type: hash.key?("type") ? hash["type"] : "default",
            data: hash["data"],
            timestamp: hash["timestamp"]
          )
        end

        def stringify_keys(hash)
          hash.each_with_object({}) do |(k, v), acc|
            acc[k.to_s] = v
          end
        end
    end

    def initialize(category: nil, message: nil, level: "info", type: "default", data: nil, timestamp: nil)
      @category = category&.to_s
      @message = message&.to_s
      @level = (level || "info").to_s
      @type = (type || "default").to_s
      @data = normalize_data(data)
      @timestamp = normalize_timestamp(timestamp)
    end

    def to_h
      result = {
        "timestamp" => @timestamp,
        "type" => @type,
        "category" => @category,
        "level" => @level,
        "message" => @message
      }.compact
      result["data"] = deep_dup_hash(@data) if @data && !@data.empty?
      result
    end

    private
      def normalize_timestamp(raw)
        case raw
        when nil
          Time.now.utc.iso8601
        when Time
          raw.utc.iso8601
        when Numeric
          Time.at(raw).utc.iso8601
        else
          str = raw.to_s.strip
          str.empty? ? Time.now.utc.iso8601 : str
        end
      end

      def normalize_data(raw)
        return nil unless raw.is_a?(Hash)

        deep_stringify(raw)
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
        when Array
          value.map { |item| deep_stringify(item) }
        else
          value
        end
      end

      def deep_dup_hash(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[k.dup] = deep_dup_hash(v) }
        when Array
          value.map { |item| deep_dup_hash(item) }
        when String
          value.dup
        else
          value
        end
      end
  end
end
