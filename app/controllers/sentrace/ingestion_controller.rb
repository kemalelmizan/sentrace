require "stringio"
require "zlib"

module Sentrace
  class IngestionController < ApplicationController
    GZIP_CHUNK_BYTES = 16 * 1024
    HEADER_PEEK_BYTES = 16 * 1024
    MAX_AUTH_HEADER_BYTES = 4 * 1024
    MAX_AUTH_HEADER_PAIRS = 16

    before_action :apply_cors_headers

    def options
      head :no_content
    end

    def envelope
      config = Sentrace.configuration
      unless config.enabled
        return render json: { id: nil }, status: :accepted
      end

      if forbidden_ingestion_origin?(config)
        return render json: { error: "Origin not allowed" }, status: :forbidden
      end

      project_id = parse_positive_project_id(params[:project_id])

      if config.ingestion_rate_limit_per_minute
        client_ip = request.remote_ip.to_s.strip.presence || "unknown"
        bucket_project = project_id || "invalid"
        rate_result = RateLimiter.check!(
          bucket: "ingestion",
          identifier: "#{bucket_project}:#{client_ip}",
          limit: config.ingestion_rate_limit_per_minute
        )
        unless rate_result[:allowed]
          response.set_header("Retry-After", rate_result[:retry_after].to_s)
          return render json: { error: "Rate limit exceeded" }, status: :too_many_requests
        end
      end

      unless project_id
        return render json: { error: "Unauthorized" }, status: :unauthorized
      end

      max_size = config.max_envelope_size
      if request.content_length && request.content_length > max_size
        return render json: { error: "Payload too large" }, status: 413
      end

      cred_source, pub_key, secret_key = extract_header_or_query_credentials
      if cred_source == :invalid
        return render json: { error: "Unauthorized" }, status: :unauthorized
      end

      matched_key = nil
      if cred_source == :supplied
        matched_key = ProjectKey.authenticate_public_key(
          project_id: project_id,
          public_key: pub_key,
          secret: secret_key
        )
        unless matched_key
          return render json: { error: "Unauthorized" }, status: :unauthorized
        end
        raw_bytes = read_bounded_stream(request.body, max_size)
      else
        peek_limit = [ HEADER_PEEK_BYTES, max_size ].min
        prefix_chunk = read_stream_prefix(request.body, peek_limit)
        matched_key = authenticate_envelope_dsn(prefix_chunk, project_id: project_id, max_size: max_size)
        unless matched_key
          return render json: { error: "Unauthorized" }, status: :unauthorized
        end
        raw_bytes = read_remaining_bounded_stream(request.body, prefix_chunk, max_size)
      end

      envelope_bytes = gzip_encoded? ? inflate_bounded_gzip(raw_bytes, max_size) : raw_bytes

      result = Ingestion::Processor.process_raw_envelope(
        envelope_bytes,
        project: matched_key.project_id,
        config: config,
        ingestion_source: "http_dsn"
      )

      render json: { id: result.primary_event_id }, status: :ok
    rescue PayloadTooLargeError
      render json: { error: "Payload too large" }, status: 413
    rescue EnvelopeParseError
      render json: { error: "Malformed envelope" }, status: :bad_request
    rescue StandardError => e
      Rails.logger&.error("[Sentrace] Ingestion error (#{e.class})")
      render json: { error: "Internal ingestion error" }, status: :internal_server_error
    end

    private
      def apply_cors_headers
        allowed_origin = Sentrace.configuration.cors_origin_header_for(request.headers["Origin"])
        return unless allowed_origin

        response.headers["Access-Control-Allow-Origin"] = allowed_origin
        response.headers["Vary"] = "Origin" unless allowed_origin == "*"
        response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type, Content-Encoding, X-Sentry-Auth, Authorization"
        response.headers["Access-Control-Max-Age"] = "86400"
      end

      def forbidden_ingestion_origin?(config)
        wildcard = config.cors_allowed_origins == "*" ||
          Array(config.cors_allowed_origins).any? { |entry| entry.to_s.strip == "*" }
        return false if wildcard

        raw_origin = request.headers["Origin"].to_s.strip
        if !raw_origin.empty?
          return true if raw_origin.casecmp("null").zero?
          return false if RequestSecurity.same_origin?(request)
          return false unless config.cors_origin_header_for(raw_origin).nil?

          return true
        end

        sec_fetch_site = request.headers["Sec-Fetch-Site"].to_s.strip.downcase
        sec_fetch_site == "cross-site"
      end

      def read_stream_prefix(io, peek_limit)
        return "".b if io.nil?

        io.rewind if io.respond_to?(:rewind)
        chunk = io.read(peek_limit + 1)
        chunk ? chunk.b : "".b
      end

      def read_remaining_bounded_stream(io, prefix_chunk, max_size)
        buffer = prefix_chunk.dup.b
        if buffer.bytesize > max_size
          raise PayloadTooLargeError, "Request body exceeds max_envelope_size"
        end
        return buffer if io.nil?

        while (chunk = io.read(GZIP_CHUNK_BYTES))
          buffer << chunk.b
          if buffer.bytesize > max_size
            raise PayloadTooLargeError, "Request body exceeds max_envelope_size"
          end
        end
        buffer
      end

      def read_bounded_stream(io, max_size)
        return "".b if io.nil?

        io.rewind if io.respond_to?(:rewind)
        buffer = "".b
        while (chunk = io.read(GZIP_CHUNK_BYTES))
          buffer << chunk.b
          if buffer.bytesize > max_size
            raise PayloadTooLargeError, "Request body exceeds max_envelope_size"
          end
        end
        buffer
      end

      def gzip_encoded?
        encoding = request.headers["Content-Encoding"].to_s.downcase
        encoding.include?("gzip")
      end

      def inflate_bounded_gzip(compressed_bytes, max_size)
        if compressed_bytes.nil? || compressed_bytes.empty?
          raise EnvelopeParseError, "Empty gzip envelope"
        end

        reader = Zlib::GzipReader.new(StringIO.new(compressed_bytes))
        inflated = "".b
        begin
          until reader.eof?
            chunk = reader.read(GZIP_CHUNK_BYTES)
            break if chunk.nil?

            inflated << chunk.b
            if inflated.bytesize > max_size
              raise PayloadTooLargeError, "Decompressed envelope exceeds max_envelope_size"
            end
          end
        ensure
          reader.close unless reader.closed?
        end
        inflated
      rescue Zlib::Error
        raise EnvelopeParseError, "Malformed gzip stream"
      end

      def parse_positive_project_id(raw_project_id)
        return raw_project_id if raw_project_id.is_a?(Integer) && raw_project_id.positive?
        return nil unless raw_project_id.is_a?(String)
        return nil unless raw_project_id.match?(/\A[1-9]\d{0,18}\z/)

        Integer(raw_project_id, 10)
      rescue ArgumentError, TypeError
        nil
      end

      def extract_header_or_query_credentials
        auth_header = request.headers["X-Sentry-Auth"].presence || sentry_authorization_header
        if auth_header
          return [ :invalid, nil, nil ] if auth_header.bytesize > MAX_AUTH_HEADER_BYTES

          parsed = parse_sentry_auth_header(auth_header)
          if parsed["sentry_key"].present?
            return [ :supplied, parsed["sentry_key"], parsed["sentry_secret"] ]
          end
        end

        if request.query_parameters.key?("sentry_key")
          raw_key = request.query_parameters["sentry_key"]
          raw_secret = request.query_parameters["sentry_secret"]
          if !raw_key.is_a?(String) || (!raw_secret.nil? && !raw_secret.is_a?(String))
            return [ :invalid, nil, nil ]
          end

          if raw_key.present?
            return [ :supplied, raw_key, raw_secret ]
          end
        end

        [ :none, nil, nil ]
      end

      def authenticate_envelope_dsn(raw_bytes, project_id:, max_size:)
        dsn_string = extract_dsn_from_envelope_prefix(raw_bytes, max_size: max_size)
        return nil if dsn_string.blank?

        parsed_dsn = Dsn.parse(dsn_string)
        return nil unless parsed_dsn.project_id.to_i == project_id

        ProjectKey.authenticate_public_key(
          project_id: project_id,
          public_key: parsed_dsn.public_key,
          secret: parsed_dsn.secret_key
        )
      rescue InvalidDsnError
        nil
      end

      def sentry_authorization_header
        raw = request.headers["Authorization"].to_s
        raw if raw.bytesize <= MAX_AUTH_HEADER_BYTES && raw.match?(/\ASentry\s+/i)
      end

      def parse_sentry_auth_header(raw_header)
        stripped = raw_header.to_s.sub(/\ASentry\s+/i, "")
        stripped.split(",", MAX_AUTH_HEADER_PAIRS + 1).first(MAX_AUTH_HEADER_PAIRS).each_with_object({}) do |pair, acc|
          key, val = pair.split("=", 2)
          next if key.nil? || val.nil?

          acc[key.strip] = val.strip
        end
      end

      def extract_dsn_from_envelope_prefix(raw_bytes, max_size:)
        peek_limit = [ HEADER_PEEK_BYTES, max_size ].min
        prefix =
          if gzip_encoded?
            peek_gzip_prefix(raw_bytes, peek_limit)
          else
            raw_bytes.byteslice(0, peek_limit)
          end
        Ingestion::EnvelopeParser.extract_header_dsn(prefix)
      end

      def peek_gzip_prefix(compressed_bytes, limit)
        return nil if compressed_bytes.nil? || compressed_bytes.empty?

        reader = Zlib::GzipReader.new(StringIO.new(compressed_bytes))
        begin
          reader.gets("\n", limit + 1)
        ensure
          begin
            reader.close unless reader.closed?
          rescue Zlib::Error
            nil
          end
        end
      rescue Zlib::Error
        nil
      end
  end
end
