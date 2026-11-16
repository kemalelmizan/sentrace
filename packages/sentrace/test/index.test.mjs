import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

import SentraceDefault, {
  VERSION,
  addBreadcrumb,
  captureException,
  captureMessage,
  getConfig,
  init,
  resetClient
} from "../dist/index.mjs";

const require = createRequire(import.meta.url);
const SentraceCjs = require("../dist/index.cjs");

test("ESM exports matching version and no-op stub lifecycle", () => {
  resetClient();
  assert.equal(VERSION, "0.0.1");
  assert.equal(SentraceDefault.VERSION, "0.0.1");
  assert.equal(getConfig(), null);

  const cfg = init({ dsn: "http://pub@localhost:3000/sentrace/1", environment: "development" });
  assert.equal(cfg.dsn, "http://pub@localhost:3000/sentrace/1");
  assert.equal(cfg.environment, "development");
  assert.equal(getConfig(), cfg);

  addBreadcrumb({ message: "Clicked checkout" });
  assert.equal(captureException(new Error("boom")), null);
  assert.equal(captureMessage("warn", "warning"), null);

  resetClient();
  assert.equal(getConfig(), null);
});

test("CommonJS require exports matching API", () => {
  SentraceCjs.resetClient();
  assert.equal(SentraceCjs.VERSION, "0.0.1");
  const cfg = SentraceCjs.init({ release: "v1.0.0" });
  assert.equal(cfg.release, "v1.0.0");
  SentraceCjs.resetClient();
});
