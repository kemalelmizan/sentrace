require "stringio"
require "zlib"

module Sentrace
  class IngestionController < ApplicationController
    GZIP_CHUNK_BYTES = 16 * 1024
    HEADER_PEEK_BYTES = 16 * 1024

    before_action :apply_cors_headers

    def options
      head :no_content
    end

    def envelope
      config = Sentrace.configuration
      unless config.enabled
        return render json: { id: nil }, status: :accepted
      end

      max_size = config.max_envelope_size
      if request.content_length && request.content_length > max_size
        return render json: { error: "Payload too large" }, status: :content_too_large
      end

      raw_bytes = read_bounded_stream(request.body, max_size)
      matched_key = authenticate_request(raw_bytes, max_size: max_size)
      unless matched_key
        return render json: { error: "Unauthorized" }, status: :unauthorized
      end

      envelope_bytes = gzip_encoded? ? inflate_bounded_gzip(raw_bytes, max_size) : raw_bytes

      result = Ingestion::Processor.process_raw_envelope(
        envelope_bytes,
        project: matched_key.project_id,
        config: config
      )

      render json: { id: result.primary_event_id }, status: :ok
    rescue PayloadTooLargeError
      render json: { error: "Payload too large" }, status: :content_too_large
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

      def authenticate_request(raw_bytes, max_size:)
        project_id = Integer(params[:project_id].to_s, 10)
        return nil if project_id <= 0

        pub_key, secret_key = extract_credentials(raw_bytes, project_id: project_id, max_size: max_size)
        return nil if pub_key.blank?

        ProjectKey.authenticate_public_key(
          project_id: project_id,
          public_key: pub_key,
          secret: secret_key
        )
      rescue ArgumentError, TypeError
        nil
      end

      def extract_credentials(raw_bytes, project_id:, max_size:)
        auth_header = request.headers["X-Sentry-Auth"].presence || sentry_authorization_header
        if auth_header
          parsed = parse_sentry_auth_header(auth_header)
          return [ parsed["sentry_key"], parsed["sentry_secret"] ] if parsed["sentry_key"].present?
        end

        if request.query_parameters["sentry_key"].present?
          return [
            request.query_parameters["sentry_key"].to_s,
            request.query_parameters["sentry_secret"]&.to_s
          ]
        end

        dsn_string = extract_dsn_from_envelope_prefix(raw_bytes, max_size: max_size)
        return [ nil, nil ] if dsn_string.blank?

        parsed_dsn = Dsn.parse(dsn_string)
        return [ nil, nil ] unless parsed_dsn.project_id.to_i == project_id

        [ parsed_dsn.public_key, parsed_dsn.secret_key ]
      rescue InvalidDsnError
        [ nil, nil ]
      end

      def sentry_authorization_header
        raw = request.headers["Authorization"].to_s
        raw if raw.match?(/\ASentry\s+/i)
      end

      def parse_sentry_auth_header(raw_header)
        stripped = raw_header.to_s.sub(/\ASentry\s+/i, "")
        stripped.split(",").each_with_object({}) do |pair, acc|
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
          reader.read(limit)
        ensure
          reader.close unless reader.closed?
        end
      rescue Zlib::Error
        nil
      end
  end
end
