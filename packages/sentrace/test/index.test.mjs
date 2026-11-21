import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

import SentraceDefault, {
  VERSION,
  addBreadcrumb,
  captureException,
  captureMessage,
  close,
  getConfig,
  init,
  isEnabled,
  lastEventId,
  resetClient,
  withScope
} from "../dist/index.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pkgRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(pkgRoot, "../..");
const require = createRequire(import.meta.url);
const SentraceCjs = require("../dist/index.cjs");

test("ESM dist/index.mjs exports 0.1.7 and delivers Sentry v7 envelopes end-to-end", async () => {
  resetClient();
  assert.equal(VERSION, "0.1.7");
  assert.equal(SentraceDefault.VERSION, "0.1.7");
  assert.equal(getConfig(), null);
  assert.equal(isEnabled(), false);
  assert.equal(lastEventId(), undefined);

  const delivered = [];
  const cfg = init({
    dsn: "https://pub123@errors.example.com/sentrace/1",
    environment: "staging",
    release: "v0.1.7",
    autoInstrumentBrowser: false,
    railsIntegration: false,
    transport: () => ({
      send: async (envelope) => {
        delivered.push(envelope);
        return { statusCode: 200 };
      },
      flush: async () => true
    })
  });

  assert.equal(cfg.dsn, "https://pub123@errors.example.com/sentrace/1");
  assert.equal(cfg.environment, "staging");
  assert.equal(getConfig(), cfg);
  assert.equal(isEnabled(), true);

  addBreadcrumb({ category: "ui.click", message: "button#buy" });
  const id = withScope((scope) => {
    scope.setTag("flow", "checkout");
    return captureException(new Error("Card declined"));
  });
  assert.match(id, /^[0-9a-f]{32}$/);
  assert.equal(lastEventId(), id);
  const msgId = captureMessage("Heads up", "warning");
  assert.equal(lastEventId(), msgId);

  assert.equal(delivered.length, 2);
  const firstPayload = JSON.parse(delivered[0].trimEnd().split("\n")[2]);
  assert.equal(firstPayload.event_id, id);
  assert.equal(firstPayload.tags.flow, "checkout");
  assert.equal(firstPayload.exception.values[0].value, "Card declined");

  await close();
  assert.equal(getConfig(), null);
  assert.equal(isEnabled(), false);
  assert.equal(lastEventId(), undefined);

  const allowDelivered = [];
  init({
    dsn: "https://pub123@errors.example.com/sentrace/1",
    allowFields: ["token_present"],
    autoInstrumentBrowser: false,
    railsIntegration: false,
    transport: () => ({
      send: async (envelope) => {
        allowDelivered.push(envelope);
        return { statusCode: 200 };
      },
      flush: async () => true
    })
  });
  SentraceDefault.captureEvent({
    message: "Calibration check",
    request: {
      url: "https://app.example.com/calibrations?calibration_session_id=77&session_id=sess_x&token_present=true&api_token=sec_y"
    }
  });
  const allowPayload = JSON.parse(allowDelivered[0].trimEnd().split("\n")[2]);
  assert.equal(
    allowPayload.request.url,
    "https://app.example.com/calibrations?calibration_session_id=77&session_id=[REDACTED]&token_present=true&api_token=[REDACTED]"
  );
  await close();
});

test("CommonJS dist/index.cjs exports matching API", async () => {
  SentraceCjs.resetClient();
  assert.equal(SentraceCjs.VERSION, "0.1.7");
  assert.equal(SentraceCjs.default.VERSION, "0.1.7");
  assert.equal(SentraceCjs.isEnabled(), false);
  assert.equal(SentraceCjs.lastEventId(), undefined);

  const cfg = SentraceCjs.init({
    dsn: "http://pub@localhost:3000/sentrace/1",
    release: "v1.0.0",
    autoInstrumentBrowser: false,
    railsIntegration: false
  });
  assert.equal(cfg.release, "v1.0.0");
  assert.equal(SentraceCjs.isEnabled(), true);
  await SentraceCjs.close();
  assert.equal(SentraceCjs.isEnabled(), false);
});

test("IIFE dist/sentrace.browser.js attaches window.Sentrace cleanly and matches synced Rails engine assets", () => {
  const browserBundlePath = path.join(pkgRoot, "dist/sentrace.browser.js");
  const esmBundlePath = path.join(pkgRoot, "dist/index.mjs");
  const railsEsmPath = path.join(repoRoot, "app/assets/javascripts/sentrace.js");
  const railsBrowserPath = path.join(repoRoot, "app/assets/javascripts/sentrace.browser.js");

  const browserCode = fs.readFileSync(browserBundlePath, "utf8");
  const esmCode = fs.readFileSync(esmBundlePath, "utf8");

  assert.equal(fs.readFileSync(railsEsmPath, "utf8"), esmCode);
  assert.equal(fs.readFileSync(railsBrowserPath, "utf8"), browserCode);

  const sandbox = {
    URL,
    URLSearchParams,
    TextEncoder,
    Date,
    Math,
    JSON,
    Object,
    Array,
    String,
    Number,
    Boolean,
    RegExp,
    Error,
    TypeError,
    Set,
    Promise,
    setTimeout,
    clearTimeout
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;

  vm.runInNewContext(browserCode, sandbox);
  assert.ok(sandbox.Sentrace);
  assert.equal(sandbox.Sentrace.VERSION, "0.1.7");
  assert.equal(sandbox.Sentrace.isEnabled(), false);

  const envelopes = [];
  sandbox.Sentrace.init({
    dsn: "https://pub_iife@app.example.com/sentrace/5",
    autoInstrumentBrowser: false,
    railsIntegration: false,
    transport: () => ({
      send: async (raw) => {
        envelopes.push(raw);
        return { statusCode: 200 };
      },
      flush: async () => true
    })
  });
  assert.equal(sandbox.Sentrace.isEnabled(), true);
  const evId = sandbox.Sentrace.captureMessage("Hello from IIFE");
  assert.match(evId, /^[0-9a-f]{32}$/);
  assert.equal(sandbox.Sentrace.lastEventId(), evId);
  assert.equal(envelopes.length, 1);
});
