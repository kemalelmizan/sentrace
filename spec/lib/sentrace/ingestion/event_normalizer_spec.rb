require "rails_helper"

RSpec.describe Sentrace::Ingestion::EventNormalizer do
  let(:config) { Sentrace::Configuration.new }
  let(:received_at) { Time.utc(2026, 11, 16, 12, 0, 0) }

  describe ".normalize" do
    it "extracts outermost exception, frames, breadcrumbs, tags, contexts, and relational metadata" do
      raw_event = {
        "event_id" => "01234567-89AB-CDEF-0123-456789ABCDEF",
        "timestamp" => "2026-11-16T11:59:30Z",
        "level" => "fatal",
        "platform" => "ruby",
        "logger" => "Rails",
        "environment" => "production",
        "release" => "v2.4.0",
        "fingerprint" => [ "{{ default }}", "checkout" ],
        "exception" => {
          "values" => [
            {
              "type" => "PG::ConnectionBad",
              "value" => "socket closed",
              "stacktrace" => {
                "frames" => [
                  { "filename" => "gems/pg/connection.rb", "function" => "exec", "lineno" => 10, "in_app" => false }
                ]
              }
            },
            {
              "type" => "ActiveRecord::StatementInvalid",
              "value" => "PG::ConnectionBad: socket closed",
              "stacktrace" => {
                "frames" => [
                  { "filename" => "gems/activerecord/connection.rb", "function" => "execute", "lineno" => 99, "in_app" => false },
                  { "filename" => "app/models/order.rb", "function" => "charge!", "lineno" => 42, "in_app" => true }
                ]
              }
            }
          ]
        },
        "breadcrumbs" => {
          "values" => [
            { "timestamp" => "2026-11-16T11:59:29Z", "category" => "sql.active_record", "message" => "SELECT 1", "level" => "info" }
          ]
        },
        "tags" => [ [ "component", "payments" ], [ "region", "ap-southeast-1" ] ],
        "contexts" => {
          "runtime" => { "name" => "ruby", "version" => "3.3.13" }
        },
        "user" => { "id" => 77, "email" => "dev@example.com" },
        "request" => { "url" => "https://shop.example.com/checkout", "method" => "post" }
      }

      normalized = described_class.normalize(raw_event, received_at: received_at, config: config)

      expect(normalized.event_id).to eq("0123456789abcdef0123456789abcdef")
      expect(normalized.occurred_at).to eq(Time.utc(2026, 11, 16, 11, 59, 30))
      expect(normalized.received_at).to eq(received_at)
      expect(normalized.level).to eq(:fatal)
      expect(normalized.platform).to eq("ruby")
      expect(normalized.logger).to eq("Rails")
      expect(normalized.environment).to eq("production")
      expect(normalized.release).to eq("v2.4.0")
      expect(normalized.exception_type).to eq("ActiveRecord::StatementInvalid")
      expect(normalized.issue_message).to eq("PG::ConnectionBad: socket closed")
      expect(normalized.culprit).to eq("app/models/order.rb in charge!")
      expect(normalized.fingerprint).to eq([ "{{ default }}", "checkout" ])

      exc = normalized.event_data["exception"]
      expect(exc["type"]).to eq("ActiveRecord::StatementInvalid")
      expect(exc["frames"].size).to eq(2)
      expect(exc["frames"].last).to eq(
        "filename" => "app/models/order.rb",
        "function" => "charge!",
        "lineno" => 42,
        "in_app" => true
      )
      expect(normalized.event_data["tags"]).to eq("component" => "payments", "region" => "ap-southeast-1")
      expect(normalized.event_data["breadcrumbs"].size).to eq(1)
      expect(normalized.event_data["contexts"]).to eq("runtime" => { "name" => "ruby", "version" => "3.3.13" })
    end

    it "truncates frames, breadcrumbs, tags, multi-byte UTF-8 messages, and contexts to configured limits" do
      config.max_stack_frames = 5
      config.max_breadcrumbs = 3
      config.max_tags = 2
      config.max_tag_key_bytes = 8
      config.max_tag_value_bytes = 10
      config.max_message_bytes = 32
      config.max_context_entries = 2
      config.max_context_bytes = 160

      # Multi-byte UTF-8 characters ("é" is 2 bytes, "🚀" is 4 bytes) to test clean UTF-8 boundary slicing
      multibyte_message = "Error 🚀🚀éééééééééééééééééééééééééé"
      frames = (1..12).map do |i|
        { "filename" => "app/step_#{i}.rb", "function" => "fn_#{i}", "lineno" => i, "in_app" => true }
      end
      breadcrumbs = (1..8).map do |i|
        { "category" => "step", "message" => "crumb #{i}" }
      end
      tags = (1..6).to_h { |i| [ "k#{i}_very_long_tag_key", "v#{i}_very_long_tag_value" ] }
      contexts = {
        "c1" => { "a" => "small" },
        "c2" => { "b" => "A" * 400 }, # exceeds max_context_bytes (160) so skipped
        "c3" => { "c" => "fits" },
        "c4" => { "d" => "over_max_entries" }
      }

      raw_event = {
        "event_id" => "abcdef0123456789abcdef0123456789",
        "timestamp" => 1_763_294_400.5,
        "logentry" => { "formatted" => multibyte_message },
        "exception" => { "values" => [ { "type" => "RuntimeError", "value" => multibyte_message, "stacktrace" => { "frames" => frames } } ] },
        "breadcrumbs" => breadcrumbs,
        "tags" => tags,
        "contexts" => contexts
      }

      normalized = described_class.normalize(raw_event, received_at: received_at, config: config)

      msg = normalized.event_data["message"]
      expect(msg.valid_encoding?).to be(true)
      expect(msg.bytesize).to be <= 32

      kept_frames = normalized.event_data.dig("exception", "frames")
      expect(kept_frames.size).to eq(5)
      expect(kept_frames.map { |f| f["lineno"] }).to eq([ 8, 9, 10, 11, 12 ])

      kept_crumbs = normalized.event_data["breadcrumbs"]
      expect(kept_crumbs.size).to eq(3)
      expect(kept_crumbs.map { |c| c["message"] }).to eq([ "crumb 6", "crumb 7", "crumb 8" ])

      kept_tags = normalized.event_data["tags"]
      expect(kept_tags.size).to eq(2)
      kept_tags.each do |k, v|
        expect(k.bytesize).to be <= 8
        expect(v.bytesize).to be <= 10
      end

      kept_contexts = normalized.event_data["contexts"]
      expect(kept_contexts.keys).to eq([ "c1", "c3" ])
      expect(JSON.generate(kept_contexts).bytesize).to be <= 160
    end

    it "raises EnvelopeParseError when event_id or timestamp is invalid" do
      expect {
        described_class.normalize({ "message" => "missing id" }, received_at: received_at)
      }.to raise_error(Sentrace::EnvelopeParseError, /event_id/i)

      expect {
        described_class.normalize(
          { "event_id" => "0123456789abcdef0123456789abcdef", "timestamp" => "not-a-timestamp" },
          received_at: received_at
        )
      }.to raise_error(Sentrace::EnvelopeParseError, /timestamp/i)
    end
  end
end
