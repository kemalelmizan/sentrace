require "rails_helper"

RSpec.describe Sentrace::Issues::Fingerprint do
  def fingerprint_for(raw_overrides)
    raw = {
      "event_id" => SecureRandom.hex(16),
      "timestamp" => "2026-11-16T12:00:00Z"
    }.merge(raw_overrides)

    normalized = Sentrace::Ingestion::EventNormalizer.normalize(raw)
    described_class.compute(normalized)
  end

  describe ".compute" do
    it "produces an identical 64-char SHA-256 hex digest across staging and production and across release paths" do
      staging_fp = fingerprint_for(
        "environment" => "staging",
        "release" => "20261115",
        "exception" => {
          "values" => [
            {
              "type" => "NoMethodError",
              "value" => "undefined method `total' for nil",
              "stacktrace" => {
                "frames" => [
                  {
                    "filename" => "/usr/local/bundle/gems/actionpack-7.2.0/lib/action_controller/base.rb",
                    "function" => "process",
                    "lineno" => 100,
                    "in_app" => false
                  },
                  {
                    "filename" => "/var/www/shop/releases/20261115/app/models/order.rb",
                    "function" => "calculate_total in #<Order:0x00007f9a11223344>",
                    "lineno" => 42,
                    "in_app" => true
                  }
                ]
              }
            }
          ]
        }
      )

      production_fp = fingerprint_for(
        "environment" => "production",
        "release" => "20261116",
        "exception" => {
          "values" => [
            {
              "type" => "NoMethodError",
              "value" => "undefined method `total' for nil (Order 99999)",
              "stacktrace" => {
                "frames" => [
                  {
                    "filename" => "/srv/bundle/gems/actionpack-7.2.2/lib/action_controller/base.rb",
                    "function" => "process",
                    "lineno" => 104,
                    "in_app" => false
                  },
                  {
                    "filename" => "/srv/shop/releases/20261116/app/models/order.rb",
                    "function" => "calculate_total in #<Order:0x00007fabdeadbeef>",
                    "lineno" => 88,
                    "in_app" => true
                  }
                ]
              }
            }
          ]
        }
      )

      expect(staging_fp).to match(/\A[0-9a-f]{64}\z/)
      expect(staging_fp).to eq(production_fp)
    end

    it "falls back to normalized framework/gem frames when no in_app frames exist" do
      fp_v1 = fingerprint_for(
        "exception" => {
          "values" => [
            {
              "type" => "PG::ConnectionBad",
              "value" => "connection closed",
              "stacktrace" => {
                "frames" => [
                  { "filename" => "/bundle/gems/pg-1.5.6/lib/pg/connection.rb", "function" => "async_exec", "in_app" => false }
                ]
              }
            }
          ]
        }
      )

      fp_v2 = fingerprint_for(
        "exception" => {
          "values" => [
            {
              "type" => "PG::ConnectionBad",
              "value" => "connection closed",
              "stacktrace" => {
                "frames" => [
                  { "filename" => "/opt/gems/pg-1.5.9/lib/pg/connection.rb", "function" => "async_exec", "in_app" => false }
                ]
              }
            }
          ]
        }
      )

      expect(fp_v1).to eq(fp_v2)
    end

    it "honors explicit custom Sentry fingerprints and {{ default }} hybrid expansion" do
      custom_one = fingerprint_for(
        "fingerprint" => [ "checkout-gateway-timeout" ],
        "exception" => {
          "values" => [
            {
              "type" => "Net::ReadTimeout",
              "stacktrace" => { "frames" => [ { "filename" => "app/services/stripe_gateway.rb", "function" => "charge", "in_app" => true } ] }
            }
          ]
        }
      )

      custom_two = fingerprint_for(
        "fingerprint" => [ "checkout-gateway-timeout" ],
        "exception" => {
          "values" => [
            {
              "type" => "Faraday::TimeoutError",
              "stacktrace" => { "frames" => [ { "filename" => "app/services/adyen_gateway.rb", "function" => "authorize", "in_app" => true } ] }
            }
          ]
        }
      )

      expect(custom_one).to eq(custom_two)

      default_only = fingerprint_for("fingerprint" => [ "{{ default }}" ], "message" => "Timeout")
      bare_default = fingerprint_for("message" => "Timeout")
      hybrid = fingerprint_for("fingerprint" => [ "{{ default }}", "tenant-enterprise" ], "message" => "Timeout")

      expect(default_only).to eq(bare_default)
      expect(hybrid).not_to eq(bare_default)
    end

    it "strips volatile UUIDs, numeric IDs, hex tokens, and timestamps in message-only events" do
      fp_a = fingerprint_for(
        "message" => "Order 12345 failed for request 550e8400-e29b-41d4-a716-446655440000 at 2026-11-16T10:15:30Z"
      )
      fp_b = fingerprint_for(
        "message" => "Order 98765 failed for request 6ba7b810-9dad-11d1-80b4-00c04fd430c8 at 2026-11-16T22:45:09Z"
      )
      fp_different = fingerprint_for(
        "message" => "Invoice 98765 succeeded for request 6ba7b810-9dad-11d1-80b4-00c04fd430c8"
      )

      expect(fp_a).to eq(fp_b)
      expect(fp_a).not_to eq(fp_different)
    end

    it "normalizes floating-point numbers and numeric+unit tokens (s, ms, %, MB) into a single message fingerprint" do
      fp_lark_seconds = fingerprint_for(
        "message" => "Slow Lark API response: 3.45s for user 812 (payload 10MB, error rate 12.5%)"
      )
      fp_lark_millis = fingerprint_for(
        "message" => "Slow Lark API response: 250ms for user 19402 (payload 2.4MB, error rate 0.8%)"
      )
      fp_lark_integer_sec = fingerprint_for(
        "message" => "Slow Lark API response: 4s for user 7 (payload 512KB, error rate 99%)"
      )
      fp_other_api = fingerprint_for(
        "message" => "Slow Slack API response: 3.45s for user 812 (payload 10MB, error rate 12.5%)"
      )

      expect(fp_lark_seconds).to eq(fp_lark_millis)
      expect(fp_lark_seconds).to eq(fp_lark_integer_sec)
      expect(fp_lark_seconds).not_to eq(fp_other_api)

      expect(described_class.normalize_message("S3 upload took 1.25s for oauth2 client 42")).to eq(
        "S3 upload took <num> for oauth2 client <num>"
      )
      expect(described_class.normalize_message("Score drift -0.375 vs threshold 1.50.")).to eq(
        "Score drift <num> vs threshold <num>."
      )
    end

    it "normalizes browser URLs, strips JS/TS asset content digests, and disambiguates anonymous frames with colno" do
      staging_js = fingerprint_for(
        "platform" => "javascript",
        "environment" => "staging",
        "exception" => {
          "values" => [
            {
              "type" => "TypeError",
              "value" => "Cannot read properties of undefined",
              "stacktrace" => {
                "frames" => [
                  {
                    "filename" => "https://staging.example.com/assets/checkout-a1b2c3d4.js?v=123",
                    "function" => "submitOrder",
                    "lineno" => 1,
                    "colno" => 420,
                    "in_app" => true
                  }
                ]
              }
            }
          ]
        }
      )

      production_js = fingerprint_for(
        "platform" => "javascript",
        "environment" => "production",
        "exception" => {
          "values" => [
            {
              "type" => "TypeError",
              "value" => "undefined is not an object",
              "stacktrace" => {
                "frames" => [
                  {
                    "filename" => "https://app.example.com/assets/checkout-B9xK2pQ1.js#chunk",
                    "function" => "submitOrder",
                    "lineno" => 1,
                    "colno" => 910,
                    "in_app" => true
                  }
                ]
              }
            }
          ]
        }
      )

      expect(staging_js).to eq(production_js)
      expect(described_class.normalize_filename("https://app.example.com/assets/order-summary.js")).to eq("assets/order-summary.js")

      anon_chrome = fingerprint_for(
        "platform" => "javascript",
        "exception" => {
          "values" => [
            {
              "type" => "Error",
              "stacktrace" => {
                "frames" => [ { "filename" => "https://app.example.com/assets/app-1234abcd.js", "function" => "<anonymous>", "lineno" => 1, "colno" => 120, "in_app" => true } ]
              }
            }
          ]
        }
      )
      anon_safari_same_spot = fingerprint_for(
        "platform" => "javascript",
        "exception" => {
          "values" => [
            {
              "type" => "Error",
              "stacktrace" => {
                "frames" => [ { "filename" => "https://app.example.com/assets/app-99887766.js", "function" => "?", "lineno" => 1, "colno" => 120, "in_app" => true } ]
              }
            }
          ]
        }
      )
      anon_different_col = fingerprint_for(
        "platform" => "javascript",
        "exception" => {
          "values" => [
            {
              "type" => "Error",
              "stacktrace" => {
                "frames" => [ { "filename" => "https://app.example.com/assets/app-99887766.js", "function" => "?", "lineno" => 1, "colno" => 8450, "in_app" => true } ]
              }
            }
          ]
        }
      )

      expect(anon_chrome).to eq(anon_safari_same_spot)
      expect(anon_chrome).not_to eq(anon_different_col)
    end
  end
end
