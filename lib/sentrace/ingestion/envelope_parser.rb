require "json"

module Sentrace
  module Ingestion
    class EnvelopeParser
      ParsedEnvelope = Data.define(:headers, :events, :discarded_item_types)

      MAX_HEADER_LINE_BYTES = 16 * 1024

      class << self
        def parse(raw_body)
          new.parse(raw_body)
        end

        def extract_header_dsn(raw_body)
          return nil if raw_body.nil? || raw_body.empty?

          binary = raw_body.b
          newline_idx = binary.index("\n")
          first_line = newline_idx ? binary.byteslice(0, newline_idx) : binary
          return nil if first_line.bytesize > MAX_HEADER_LINE_BYTES

          parsed = JSON.parse(first_line.force_encoding(Encoding::UTF_8))
          parsed.is_a?(Hash) ? parsed["dsn"] : nil
        rescue JSON::ParserError, EncodingError
          nil
        end
      end

      def parse(raw_body)
        if raw_body.nil? || raw_body.bytesize.zero?
          raise EnvelopeParseError, "Envelope body cannot be empty"
        end

        buffer = raw_body.b
        cursor = 0
        total = buffer.bytesize

        header_line, cursor = read_line(buffer, cursor, total)
        if header_line.nil? || header_line.empty?
          raise EnvelopeParseError, "Missing envelope header"
        end

        envelope_headers = parse_json_object(header_line, "envelope header")
        events = []
        discarded = []

        while cursor < total
          # Skip trailing newline(s) at the end of an envelope
          if buffer.getbyte(cursor) == 10
            cursor += 1
            next
          elsif buffer.getbyte(cursor) == 13 && cursor + 1 < total && buffer.getbyte(cursor + 1) == 10
            cursor += 2
            next
          end

          item_header_line, cursor = read_line(buffer, cursor, total)
          break if item_header_line.nil? || item_header_line.empty?

          item_header = parse_json_object(item_header_line, "envelope item header")
          item_type = (item_header["type"] || "event").to_s

          payload_bytes, cursor = read_item_payload(buffer, cursor, total, item_header)

          if item_type == "event"
            event_hash = parse_json_object(payload_bytes, "event payload")
            if event_hash["type"].to_s == "transaction"
              discarded << "transaction"
            else
              events << event_hash
            end
          else
            discarded << item_type
          end
        end

        ParsedEnvelope.new(
          headers: envelope_headers,
          events: events,
          discarded_item_types: discarded
        )
      end

      private
        def read_line(buffer, cursor, total)
          return [ nil, total ] if cursor >= total

          newline_idx = buffer.index("\n", cursor)
          if newline_idx
            line = buffer.byteslice(cursor, newline_idx - cursor)
            line = line.byteslice(0, line.bytesize - 1) if line.end_with?("\r")
            [ line, newline_idx + 1 ]
          else
            line = buffer.byteslice(cursor, total - cursor)
            line = line.byteslice(0, line.bytesize - 1) if line.end_with?("\r")
            [ line, total ]
          end
        end

        def read_item_payload(buffer, cursor, total, item_header)
          if item_header.key?("length")
            length = item_header["length"]
            unless length.is_a?(Integer) && length >= 0
              raise EnvelopeParseError, "Invalid item length in envelope item header"
            end

            if cursor + length > total
              raise EnvelopeParseError, "Truncated envelope item payload (expected #{length} bytes)"
            end

            payload = buffer.byteslice(cursor, length)
            next_cursor = cursor + length
            if next_cursor < total && buffer.getbyte(next_cursor) == 13 && next_cursor + 1 < total && buffer.getbyte(next_cursor + 1) == 10
              next_cursor += 2
            elsif next_cursor < total && buffer.getbyte(next_cursor) == 10
              next_cursor += 1
            end

            [ payload, next_cursor ]
          else
            read_line(buffer, cursor, total)
          end
        end

        def parse_json_object(raw_bytes, label)
          utf8 = raw_bytes.dup.force_encoding(Encoding::UTF_8)
          unless utf8.valid_encoding?
            raise EnvelopeParseError, "Invalid UTF-8 encoding in #{label}"
          end

          parsed = JSON.parse(utf8)
          unless parsed.is_a?(Hash)
            raise EnvelopeParseError, "Expected JSON object for #{label}"
          end

          parsed
        rescue JSON::ParserError
          raise EnvelopeParseError, "Invalid JSON in #{label}"
        end
    end
  end
end
