require "rails_helper"

RSpec.describe Sentrace::Ingestion::EnvelopeParser do
  describe ".extract_header_dsn" do
    it "extracts the dsn from the first JSON line without parsing items" do
      raw = %({"event_id":"0123456789abcdef0123456789abcdef","dsn":"https://pub123@errors.example.com/1"}\nnot-even-json-item)
      expect(described_class.extract_header_dsn(raw)).to eq("https://pub123@errors.example.com/1")
    end

    it "returns nil for empty, oversized, or malformed header lines" do
      expect(described_class.extract_header_dsn(nil)).to be_nil
      expect(described_class.extract_header_dsn("")).to be_nil
      expect(described_class.extract_header_dsn("not-json\n{}")).to be_nil
      oversized = %({"dsn":"#{"a" * 20_000}"}\n)
      expect(described_class.extract_header_dsn(oversized)).to be_nil
    end
  end

  describe ".parse" do
    it "parses a single newline-delimited error event envelope" do
      envelope = [
        { event_id: "0123456789abcdef0123456789abcdef", sent_at: "2026-11-16T00:00:00Z" }.to_json,
        { type: "event" }.to_json,
        { event_id: "0123456789abcdef0123456789abcdef", message: "Something broke" }.to_json
      ].join("\n") + "\n"

      parsed = described_class.parse(envelope)

      expect(parsed.headers["event_id"]).to eq("0123456789abcdef0123456789abcdef")
      expect(parsed.events.size).to eq(1)
      expect(parsed.events.first["message"]).to eq("Something broke")
      expect(parsed.discarded_item_types).to be_empty
    end

    it "parses multi-item envelopes with byte-accurate binary attachments and discards unsupported item types" do
      binary_attachment = "PNG\r\n\x00\xFFembedded\nnewlines\nand\xffbytes".b
      event_one = { event_id: "11111111111111111111111111111111", message: "First error" }.to_json
      event_two = { event_id: "22222222222222222222222222222222", message: "Second error" }.to_json
      tx_payload = { event_id: "33333333333333333333333333333333", type: "transaction" }.to_json

      raw = "".b
      raw << %({"sent_at":"2026-11-16T00:00:00Z"}\n).b
      raw << %({"type":"event","length":#{event_one.bytesize}}\n).b << event_one.b << "\n".b
      raw << %({"type":"attachment","filename":"dump.bin","length":#{binary_attachment.bytesize}}\n).b << binary_attachment << "\n".b
      raw << %({"type":"transaction"}\n{"spans":[]}\n).b
      raw << %({"type":"event"}\n).b << tx_payload.b << "\n".b
      raw << %({"type":"session"}\n{"sid":"abc"}\n).b
      raw << %({"type":"sessions"}\n{"aggregates":[]}\n).b
      raw << %({"type":"client_report"}\n{"discarded_events":[]}\n).b
      raw << %({"type":"profile"}\n{"profile":{}}\n).b
      raw << %({"type":"replay_event"}\n{}\n).b
      raw << %({"type":"replay_recording","length":4}\n1234\n).b
      raw << %({"type":"mystery_future_item"}\n{"ignored":true}\n).b
      raw << %({"type":"event","length":#{event_two.bytesize}}\n).b << event_two.b

      parsed = described_class.parse(raw)

      expect(parsed.events.map { |e| e["message"] }).to eq([ "First error", "Second error" ])
      expect(parsed.discarded_item_types).to eq(
        %w[
          attachment
          transaction
          transaction
          session
          sessions
          client_report
          profile
          replay_event
          replay_recording
          mystery_future_item
        ]
      )
    end

    it "raises EnvelopeParseError on empty, truncated, or invalid JSON envelopes" do
      expect { described_class.parse("") }.to raise_error(Sentrace::EnvelopeParseError, /empty/i)
      expect { described_class.parse("not-json\n") }.to raise_error(Sentrace::EnvelopeParseError, /envelope header/i)
      expect { described_class.parse("[]\n") }.to raise_error(Sentrace::EnvelopeParseError, /JSON object/i)

      truncated_binary = %({}\n{"type":"event","length":50}\n{"short":true})
      expect {
        described_class.parse(truncated_binary)
      }.to raise_error(Sentrace::EnvelopeParseError, /Truncated envelope item payload/i)

      bad_event_json = %({}\n{"type":"event"}\n{broken-json)
      expect {
        described_class.parse(bad_event_json)
      }.to raise_error(Sentrace::EnvelopeParseError, /Invalid JSON in event payload/i)
    end
  end
end
