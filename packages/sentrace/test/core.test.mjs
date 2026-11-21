import assert from "node:assert/strict";
import test from "node:test";

import { buildEnvelopeEndpoint, formatPublicDsn, parseDsn, scrubUrl } from "../src/dsn.ts";
import { generateEventId, serializeEnvelope } from "../src/envelope.ts";
import { Scope } from "../src/scope.ts";
import { extractExceptionChain, parseStackFrames } from "../src/stacktrace.ts";
import { createBrowserTransport } from "../src/transport.ts";

test("parseDsn, formatPublicDsn, buildEnvelopeEndpoint, and scrubUrl handle Sentrace/Sentry URLs and redact secrets", () => {
  const dsn = parseDsn("https://pub_abc123:accidental_secret@errors.example.com:8443/sentrace/42");
  assert.ok(dsn);
  assert.equal(dsn.protocol, "https");
  assert.equal(dsn.publicKey, "pub_abc123");
  assert.equal(dsn.host, "errors.example.com");
  assert.equal(dsn.port, "8443");
  assert.equal(dsn.pathPrefix, "/sentrace");
  assert.equal(dsn.projectId, "42");

  assert.equal(formatPublicDsn(dsn), "https://pub_abc123@errors.example.com:8443/sentrace/42");
  assert.equal(
    buildEnvelopeEndpoint(dsn),
    "https://errors.example.com:8443/sentrace/api/42/envelope?sentry_key=pub_abc123&sentry_version=7&sentry_client=sentrace-js%2F0.1.7"
  );

  assert.equal(parseDsn("not-a-dsn"), null);
  assert.equal(parseDsn("https://errors.example.com/42"), null);
  assert.equal(parseDsn("https://pub_abc@errors.example.com/sentrace/../../admin"), null);
  assert.equal(parseDsn("https://pub_abc@errors.example.com/sentrace/not-a-number"), null);
  assert.equal(parseDsn("javascript://pub_abc@errors.example.com/42"), null);

  assert.equal(
    scrubUrl("https://user:pass@shop.example.com/reset?token=secret123&step=2&custom_pin=9999", ["custom_pin"]),
    "https://shop.example.com/reset?token=[REDACTED]&step=2&custom_pin=[REDACTED]"
  );
  assert.equal(scrubUrl("/checkout?api_key=xyz&ok=1"), "/checkout?api_key=[REDACTED]&ok=1");
  assert.equal(
    scrubUrl("/login?api-key=k1&private-key=k2&login-otp=123456&user_ssn=999&classname=btn&rootpath=/app"),
    "/login?api-key=[REDACTED]&private-key=[REDACTED]&login-otp=[REDACTED]&user_ssn=[REDACTED]&classname=btn&rootpath=%2Fapp"
  );
  assert.equal(
    scrubUrl(
      "/calibrations?calibration_session_id=42&promotion_calibration_session_id=99&session_id=sess_1&_myapp_session=cookie_2&user_session_token=tok_3&TOKEN_PRESENT=1&access_token=sec_4",
      [],
      ["token_present"]
    ),
    "/calibrations?calibration_session_id=42&promotion_calibration_session_id=99&session_id=[REDACTED]&_myapp_session=[REDACTED]&user_session_token=[REDACTED]&TOKEN_PRESENT=1&access_token=[REDACTED]"
  );

  // Strip OAuth / SPA #hash fragments and cloud signed-URL parameters
  assert.equal(
    scrubUrl("https://shop.example.com/auth/callback?ok=1#access_token=opaque_oauth_secret&id_token=jwt_secret"),
    "https://shop.example.com/auth/callback?ok=1"
  );
  assert.equal(
    scrubUrl("/auth/callback?state=xyz#access_token=opaque_oauth_secret"),
    "/auth/callback?state=xyz"
  );
  assert.equal(
    scrubUrl("https://storage.example.com/file.pdf?X-Amz-Signature=amz123&X-Goog-Signature=gcp456&sig=s789&jwt=j000&v=1"),
    "https://storage.example.com/file.pdf?X-Amz-Signature=[REDACTED]&X-Goog-Signature=[REDACTED]&sig=[REDACTED]&jwt=[REDACTED]&v=1"
  );
});

test("parseStackFrames scrubs frame URL secrets and resists quadratic backtracking on pathological inputs", () => {
  const secretFrameStack = [
    "Error: Script failure",
    "    at loadWidget (https://app.example.com/embed.js?api_key=leak_me&custom_pin=9999&v=2#access_token=hash_leak:14:9)"
  ].join("\n");
  const scrubbedFrames = parseStackFrames(secretFrameStack, 50, ["custom_pin"]);
  assert.equal(scrubbedFrames.length, 1);
  assert.equal(scrubbedFrames[0].filename, "https://app.example.com/embed.js?api_key=[REDACTED]&custom_pin=[REDACTED]&v=2");
  assert.equal(scrubbedFrames[0].lineno, 14);
  assert.equal(scrubbedFrames[0].colno, 9);

  const adversarialV8 = "at " + "a (".repeat(1500) + "no-frame";
  const adversarialGecko = " ".repeat(3500) + "a:1:1x";
  const oversizedLine = "    at fn (https://app.example.com/" + "a".repeat(10000) + ".js:1:1)";
  const started = Date.now();
  const parsed = parseStackFrames([adversarialV8, adversarialGecko, oversizedLine].join("\n"));
  const elapsedMs = Date.now() - started;
  assert.equal(parsed.length, 0);
  assert.ok(elapsedMs < 100, `Expected linear stack parse < 100ms, took ${elapsedMs}ms`);
});

test("parseStackFrames parses V8, Firefox, and Safari stacks into oldest-to-newest Sentry frames", () => {
  const v8Stack = [
    "TypeError: Cannot read properties of null (reading 'submit')",
    "    at submitOrder (https://app.example.com/assets/checkout-a1b2c3d4.js:18:42)",
    "    at HTMLButtonElement.<anonymous> (https://app.example.com/assets/checkout-a1b2c3d4.js:5:10)",
    "    at dispatch (https://app.example.com/node_modules/@hotwired/stimulus/dist/stimulus.js:100:12)"
  ].join("\n");

  const v8Frames = parseStackFrames(v8Stack);
  assert.equal(v8Frames.length, 3);
  assert.equal(v8Frames[0].function, "dispatch");
  assert.equal(v8Frames[0].in_app, false);
  assert.equal(v8Frames[1].function, "HTMLButtonElement.<anonymous>");
  assert.equal(v8Frames[2].function, "submitOrder");
  assert.equal(v8Frames[2].lineno, 18);
  assert.equal(v8Frames[2].colno, 42);
  assert.equal(v8Frames[2].in_app, true);

  const firefoxStack = [
    "submitOrder@https://app.example.com/assets/checkout.js:18:42",
    "@https://app.example.com/assets/checkout.js:5:10"
  ].join("\n");

  const ffFrames = parseStackFrames(firefoxStack);
  assert.equal(ffFrames.length, 2);
  assert.equal(ffFrames[0].function, "?");
  assert.equal(ffFrames[1].function, "submitOrder");
  assert.equal(ffFrames[1].colno, 42);

  const safariStack = [
    "submitOrder@https://app.example.com/assets/checkout.js:18:42",
    "global code@https://app.example.com/assets/checkout.js:1:1"
  ].join("\n");

  const safariFrames = parseStackFrames(safariStack);
  assert.equal(safariFrames.length, 2);
  assert.equal(safariFrames[0].function, "?");
  assert.equal(safariFrames[1].function, "submitOrder");

  const rootCause = new Error("HTTP 500 Internal Server Error");
  const outer = new TypeError("Checkout failed", { cause: rootCause });
  const chain = extractExceptionChain(outer);
  assert.equal(chain.length, 2);
  assert.equal(chain[0].value, "HTTP 500 Internal Server Error");
  assert.equal(chain[1].type, "TypeError");
  assert.equal(chain[1].value, "Checkout failed");
});

test("Scope isolates clones, bounds breadcrumbs, and serializes valid 3-line Sentry v7 envelopes", async () => {
  const scope = new Scope();
  scope.setTag("tenant", "acme");
  scope.setUser({ id: 99, email: "alice@example.com" });
  scope.addBreadcrumb({ category: "ui.click", message: "button#1" }, 2);
  scope.addBreadcrumb({ category: "ui.click", message: "button#2" }, 2);
  scope.addBreadcrumb({ category: "ui.click", message: "button#3" }, 2);

  const cloned = scope.clone();
  cloned.setTag("scoped_only", "yes");
  assert.equal(scope.getTag("scoped_only"), undefined);

  const dsn = parseDsn("https://pub123@errors.example.com/sentrace/1");
  const eventId = generateEventId();
  assert.match(eventId, /^[0-9a-f]{32}$/);

  const event = cloned.applyToEvent(
    {
      event_id: eventId,
      timestamp: "2026-11-16T12:00:00.000Z",
      platform: "javascript",
      message: "Checkout failed"
    },
    2
  );

  assert.equal(event.tags.tenant, "acme");
  assert.equal(event.tags.scoped_only, "yes");
  assert.equal(event.breadcrumbs.values.length, 2);
  assert.equal(event.breadcrumbs.values[0].message, "button#2");
  assert.equal(event.breadcrumbs.values[1].message, "button#3");

  const rawEnvelope = serializeEnvelope(event, dsn);
  const lines = rawEnvelope.trimEnd().split("\n");
  assert.equal(lines.length, 3);
  const header = JSON.parse(lines[0]);
  const itemHeader = JSON.parse(lines[1]);
  const payload = JSON.parse(lines[2]);
  assert.equal(header.event_id, eventId);
  assert.equal(header.dsn, "https://pub123@errors.example.com/sentrace/1");
  assert.equal(itemHeader.type, "event");
  assert.equal(payload.message, "Checkout failed");

  // Verify transport fetch & sendBeacon fallback
  const sentRequests = [];
  const originalFetch = globalThis.fetch;
  const originalNav = globalThis.navigator;
  try {
    globalThis.fetch = async (url, init) => {
      sentRequests.push({ url, init });
      return { status: 200 };
    };
    const transport = createBrowserTransport(buildEnvelopeEndpoint(dsn));
    const res = await transport.send(rawEnvelope);
    assert.equal(res.statusCode, 200);
    assert.equal(await transport.flush(500), true);
    assert.equal(sentRequests.length, 1);
    assert.equal(sentRequests[0].init.keepalive, true);
    assert.equal(sentRequests[0].init.headers["Content-Type"], "text/plain;charset=UTF-8");

    let beaconCalled = false;
    globalThis.fetch = async () => {
      throw new Error("Network offline");
    };
    Object.defineProperty(globalThis, "navigator", {
      configurable: true,
      value: {
        sendBeacon: (_url, _body) => {
          beaconCalled = true;
          return true;
        }
      }
    });
    const fallbackRes = await transport.send(rawEnvelope);
    assert.equal(beaconCalled, true);
    assert.equal(fallbackRes.statusCode, 200);

    // Verify circular-reference safety in serializeEnvelope and backslash origin guard
    const circularObj = { name: "root" };
    circularObj.self = circularObj;
    const circularEnv = serializeEnvelope(
      {
        event_id: eventId,
        timestamp: "2026-11-16T12:00:00.000Z",
        platform: "javascript",
        extra: { loop: circularObj }
      },
      dsn
    );
    const circularPayload = JSON.parse(circularEnv.trimEnd().split("\n")[2]);
    assert.equal(circularPayload.extra.loop.self, "[Circular]");
  } finally {
    globalThis.fetch = originalFetch;
    if (originalNav !== undefined) {
      Object.defineProperty(globalThis, "navigator", { configurable: true, value: originalNav });
    }
  }
});
