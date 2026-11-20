import assert from "node:assert/strict";
import test from "node:test";

import * as Sentrace from "../src/index.ts";

function createFakeBrowserEnv(metaTags = {}, href = "https://shop.example.com/checkout?token=secret99&item=book") {
  const winListeners = new Map();
  const docListeners = new Map();
  const currentMeta = { ...metaTags };

  const fakeWindow = {
    location: { href },
    history: {
      pushState(_state, _title, url) {
        if (url) {
          fakeWindow.location.href = new URL(url, fakeWindow.location.href).toString();
        }
      },
      replaceState(_state, _title, url) {
        if (url) {
          fakeWindow.location.href = new URL(url, fakeWindow.location.href).toString();
        }
      }
    },
    addEventListener(type, fn) {
      const arr = winListeners.get(type) ?? [];
      arr.push(fn);
      winListeners.set(type, arr);
    },
    removeEventListener(type, fn) {
      const arr = winListeners.get(type) ?? [];
      winListeners.set(
        type,
        arr.filter((item) => item !== fn)
      );
    },
    dispatch(type, event) {
      for (const fn of winListeners.get(type) ?? []) {
        fn(event);
      }
    }
  };

  const fakeDocument = {
    visibilityState: "visible",
    querySelector(selector) {
      const m = /^meta\[name="([^"]+)"\]$/.exec(selector);
      if (!m) {
        return null;
      }
      const val = currentMeta[m[1]];
      return val !== undefined ? { getAttribute: (attr) => (attr === "content" ? val : null), content: val } : null;
    },
    addEventListener(type, fn) {
      const arr = docListeners.get(type) ?? [];
      arr.push(fn);
      docListeners.set(type, arr);
    },
    removeEventListener(type, fn) {
      const arr = docListeners.get(type) ?? [];
      docListeners.set(
        type,
        arr.filter((item) => item !== fn)
      );
    },
    dispatch(type, event) {
      for (const fn of docListeners.get(type) ?? []) {
        fn(event);
      }
    },
    setMeta(name, value) {
      currentMeta[name] = value;
    }
  };

  return { fakeWindow, fakeDocument };
}

function createMemoryTransport() {
  const envelopes = [];
  return {
    envelopes,
    factory: () => ({
      send: async (raw) => {
        const [header, itemHeader, payload] = raw.trimEnd().split("\n");
        envelopes.push({
          raw,
          header: JSON.parse(header),
          itemHeader: JSON.parse(itemHeader),
          event: JSON.parse(payload)
        });
        return { statusCode: 200 };
      },
      flush: async () => true
    })
  };
}

test("@sentry/browser-compatible API supports withScope, setTag/setUser/setExtra, ignoreErrors, denyUrls, and beforeSend", async () => {
  Sentrace.resetClient();
  const mem = createMemoryTransport();

  Sentrace.init({
    dsn: "https://pub123@errors.example.com/sentrace/9",
    environment: "staging",
    release: "v2.0.0",
    autoInstrumentBrowser: false,
    railsIntegration: false,
    ignoreErrors: [/ResizeObserver loop/],
    denyUrls: ["chrome-extension://"],
    beforeSend(event) {
      if (event.tags?.drop === "yes") {
        return null;
      }
      event.tags = { ...(event.tags ?? {}), before_send: "applied" };
      return event;
    },
    transport: mem.factory
  });

  assert.equal(Sentrace.isInitialized(), true);
  Sentrace.setTag("global_tag", "g1");
  Sentrace.setUser({ id: "u-42", email: "user@example.com" });
  Sentrace.setExtra("cart_count", 3);
  Sentrace.setContext("checkout", { provider: "stripe" });
  Sentrace.addBreadcrumb({ category: "auth", message: "Signed in" });

  // Ignored by ignoreErrors
  Sentrace.captureException(new Error("ResizeObserver loop completed with undelivered notifications"));
  // Dropped by beforeSend
  Sentrace.captureMessage("Should drop", { tags: { drop: "yes" } });
  // Denied by denyUrls
  const extErr = new Error("Extension crash");
  extErr.stack = "Error: Extension crash\n    at run (chrome-extension://abcdef/content.js:1:5)";
  Sentrace.captureException(extErr);
  assert.equal(mem.envelopes.length, 0);

  // Scoped capture
  const eventId = Sentrace.withScope((scope) => {
    scope.setTag("scoped_tag", "s1");
    return Sentrace.captureException(new TypeError("Invalid coupon"));
  });
  assert.match(eventId, /^[0-9a-f]{32}$/);
  assert.equal(mem.envelopes.length, 1);

  const captured = mem.envelopes[0].event;
  assert.equal(captured.event_id, eventId);
  assert.equal(captured.environment, "staging");
  assert.equal(captured.release, "v2.0.0");
  assert.equal(captured.tags.global_tag, "g1");
  assert.equal(captured.tags.scoped_tag, "s1");
  assert.equal(captured.tags.before_send, "applied");
  assert.equal(captured.extra.cart_count, 3);
  assert.equal(captured.contexts.checkout.provider, "stripe");
  assert.equal(captured.user.id, "u-42");
  assert.equal(captured.breadcrumbs.values.length, 1);

  // Subsequent capture outside withScope must NOT carry scoped_tag
  Sentrace.captureMessage("Post-scope warning", "warning");
  assert.equal(mem.envelopes.length, 2);
  assert.equal(mem.envelopes[1].event.level, "warning");
  assert.equal(mem.envelopes[1].event.tags.scoped_tag, undefined);

  await Sentrace.close();
  assert.equal(Sentrace.isInitialized(), false);
});

test("Zero-arg init() discovers Rails meta tags, correlates fetch X-Request-Id, and captures Turbo & Stimulus errors", async () => {
  Sentrace.resetClient();
  const prevWin = globalThis.window;
  const prevDoc = globalThis.document;
  const prevFetch = globalThis.fetch;

  const { fakeWindow, fakeDocument } = createFakeBrowserEnv({
    "sentrace-dsn": "https://pub_rails@shop.example.com/sentrace/3",
    "sentrace-environment": "production",
    "sentrace-release": "sha-abcdef1",
    "sentrace-request-id": "req-initial-100"
  });

  const mem = createMemoryTransport();

  try {
    globalThis.window = fakeWindow;
    globalThis.document = fakeDocument;
    globalThis.fetch = async (url) => {
      if (String(url).includes("/orders")) {
        return {
          status: 500,
          headers: {
            get: (k) => (k.toLowerCase() === "x-request-id" ? "req-orders-500" : null)
          }
        };
      }
      return { status: 200, headers: { get: () => null } };
    };

    const cfg = Sentrace.init({ transport: mem.factory });
    assert.equal(cfg.dsn, "https://pub_rails@shop.example.com/sentrace/3");
    assert.equal(cfg.environment, "production");
    assert.equal(cfg.release, "sha-abcdef1");

    // 1. UI click + navigation + failed fetch with Rails X-Request-Id
    fakeDocument.dispatch("click", {
      target: {
        tagName: "BUTTON",
        id: "place-order",
        className: "btn primary",
        getAttribute: (name) => (name === "type" ? "submit" : null)
      }
    });
    fakeWindow.history.pushState({}, "", "/checkout/confirm?token=topsecret&step=review");
    await globalThis.fetch("https://shop.example.com/orders?api_key=hide_me", { method: "POST" });

    // Unhandled rejection right after the failed /orders fetch inherits correlated request_id!
    fakeWindow.dispatch("unhandledrejection", { reason: new Error("Order submission rejected") });

    assert.equal(mem.envelopes.length, 1);
    const first = mem.envelopes[0].event;
    assert.equal(first.tags.request_id, "req-orders-500");
    assert.equal(first.request.url, "https://shop.example.com/checkout/confirm?token=[REDACTED]&step=review");
    assert.equal(first.breadcrumbs.values.length, 3);
    assert.equal(first.breadcrumbs.values[0].message, 'button#place-order.btn.primary[type="submit"]');
    assert.equal(
      first.breadcrumbs.values[1].data.to,
      "https://shop.example.com/checkout/confirm?token=[REDACTED]&step=review"
    );
    assert.equal(first.breadcrumbs.values[2].data.url, "https://shop.example.com/orders?api_key=[REDACTED]");
    assert.equal(first.breadcrumbs.values[2].data.request_id, "req-orders-500");

    // 2. Turbo navigation updates request_id on turbo:load and captures turbo:frame-missing
    fakeDocument.dispatch("turbo:visit", { detail: { url: "https://shop.example.com/cart", action: "advance" } });
    fakeDocument.setMeta("sentrace-request-id", "req-turbo-200");
    fakeDocument.dispatch("turbo:load", {});
    fakeDocument.dispatch("turbo:frame-missing", {
      target: { id: "cart_drawer" },
      detail: {
        response: {
          url: "https://shop.example.com/cart/drawer",
          status: 500,
          headers: { get: (k) => (k.toLowerCase() === "x-request-id" ? "req-frame-500" : null) }
        }
      }
    });

    assert.equal(mem.envelopes.length, 2);
    const turboEv = mem.envelopes[1].event;
    assert.equal(turboEv.exception.values[0].type, "TurboFrameMissingError");
    assert.equal(turboEv.tags["turbo.frame"], "cart_drawer");
    assert.equal(turboEv.tags.request_id, "req-frame-500");

    // 3. Stimulus controller error handler preserves original handler and attaches controller/action metadata
    let originalStimulusCalled = false;
    const fakeStimulusApp = {
      handleError(_err, _msg) {
        originalStimulusCalled = true;
      }
    };
    const detachStimulus = Sentrace.registerStimulusErrorHandler(fakeStimulusApp);
    fakeStimulusApp.handleError(new ReferenceError("priceTarget is not defined"), "Error invoking action", {
      identifier: "checkout-form",
      action: "click->checkout-form#recalculate"
    });

    assert.equal(originalStimulusCalled, true);
    assert.equal(mem.envelopes.length, 3);
    const stimEv = mem.envelopes[2].event;
    assert.equal(stimEv.exception.values[0].type, "ReferenceError");
    assert.equal(stimEv.tags["stimulus.controller"], "checkout-form");
    assert.equal(stimEv.tags["stimulus.action"], "click->checkout-form#recalculate");

    detachStimulus();
    await Sentrace.close();
  } finally {
    globalThis.window = prevWin;
    globalThis.document = prevDoc;
    globalThis.fetch = prevFetch;
    Sentrace.resetClient();
  }
});

test("XMLHttpRequest instrumentation survives getResponseHeader throwing on aborted/cross-origin requests and preserves falsy options", async () => {
  Sentrace.resetClient();
  const prevWin = globalThis.window;
  const prevDoc = globalThis.document;
  const prevXhr = globalThis.XMLHttpRequest;

  const { fakeWindow, fakeDocument } = createFakeBrowserEnv({});
  const mem = createMemoryTransport();

  class FakeXMLHttpRequest {
    constructor() {
      this.status = 0;
      this.listeners = new Map();
      this.throwOnGetHeader = false;
      this.headers = {};
    }

    open(_method, _url) {}

    send(_body) {
      const fns = this.listeners.get("loadend") ?? [];
      for (const fn of fns) {
        fn();
      }
    }

    addEventListener(type, fn) {
      const arr = this.listeners.get(type) ?? [];
      arr.push(fn);
      this.listeners.set(type, arr);
    }

    getResponseHeader(name) {
      if (this.throwOnGetHeader) {
        throw new Error("InvalidStateError: Failed to execute 'getResponseHeader' on 'XMLHttpRequest'");
      }
      return this.headers[name.toLowerCase()] ?? null;
    }
  }

  try {
    globalThis.window = fakeWindow;
    globalThis.document = fakeDocument;
    globalThis.XMLHttpRequest = FakeXMLHttpRequest;

    // Verify falsy numeric/boolean options are preserved (enabled: false, sampleRate: 0, maxBreadcrumbs: 0)
    const disabledCfg = Sentrace.init({
      dsn: "https://pub_xhr@shop.example.com/sentrace/3",
      enabled: false,
      sampleRate: 0,
      maxBreadcrumbs: 0,
      maxStackFrames: 0,
      autoInstrumentBrowser: false,
      railsIntegration: false,
      transport: mem.factory
    });
    assert.equal(disabledCfg.enabled, false);
    assert.equal(disabledCfg.sampleRate, 0);
    assert.equal(disabledCfg.maxBreadcrumbs, 0);
    assert.equal(disabledCfg.maxStackFrames, 0);

    // Re-init with browser XHR instrumentation active
    Sentrace.init({
      dsn: "https://pub_xhr@shop.example.com/sentrace/3",
      railsIntegration: false,
      transport: mem.factory
    });

    // 1. Aborted/CORS XHR whose getResponseHeader throws MUST NOT throw uncaught error
    const abortedXhr = new FakeXMLHttpRequest();
    abortedXhr.throwOnGetHeader = true;
    abortedXhr.status = 0;
    abortedXhr.open("GET", "https://cdn.other-origin.example/asset.json?token=sec123&v=1");
    assert.doesNotThrow(() => {
      abortedXhr.send();
    });

    // 2. Failing Rails XHR with valid X-Request-Id correlates request_id tag
    const failedXhr = new FakeXMLHttpRequest();
    failedXhr.status = 502;
    failedXhr.headers["x-request-id"] = "req-xhr-502";
    failedXhr.open("POST", "https://shop.example.com/api/checkout?api_key=sec999");
    failedXhr.send();

    Sentrace.captureException(new Error("XHR checkout failed"));
    assert.equal(mem.envelopes.length, 1);

    const captured = mem.envelopes[0].event;
    assert.equal(captured.tags.request_id, "req-xhr-502");
    assert.equal(captured.breadcrumbs.values.length, 2);
    assert.equal(captured.breadcrumbs.values[0].category, "xhr");
    assert.equal(
      captured.breadcrumbs.values[0].data.url,
      "https://cdn.other-origin.example/asset.json?token=[REDACTED]&v=1"
    );
    assert.equal(captured.breadcrumbs.values[0].data.request_id, undefined);
    assert.equal(captured.breadcrumbs.values[1].category, "xhr");
    assert.equal(captured.breadcrumbs.values[1].data.request_id, "req-xhr-502");
    assert.equal(captured.breadcrumbs.values[1].data.status_code, 502);

    await Sentrace.close();
  } finally {
    globalThis.window = prevWin;
    globalThis.document = prevDoc;
    globalThis.XMLHttpRequest = prevXhr;
    Sentrace.resetClient();
  }
});

test("isEnabled() and lastEventId() reflect client lifecycle and ignore filtered or dropped events", async () => {
  Sentrace.resetClient();
  const mem = createMemoryTransport();

  assert.equal(Sentrace.isInitialized(), false);
  assert.equal(Sentrace.isEnabled(), false);
  assert.equal(Sentrace.lastEventId(), undefined);

  // Disabled client -> isEnabled() === false, captures do not update lastEventId()
  Sentrace.init({
    dsn: "https://pub123@errors.example.com/sentrace/9",
    enabled: false,
    autoInstrumentBrowser: false,
    railsIntegration: false,
    transport: mem.factory
  });
  assert.equal(Sentrace.isInitialized(), true);
  assert.equal(Sentrace.isEnabled(), false);
  Sentrace.captureException(new Error("While disabled"));
  assert.equal(Sentrace.lastEventId(), undefined);

  // Missing/invalid DSN -> isEnabled() === false
  Sentrace.init({
    dsn: "",
    enabled: true,
    autoInstrumentBrowser: false,
    railsIntegration: false,
    transport: mem.factory
  });
  assert.equal(Sentrace.isEnabled(), false);

  // Re-init with valid DSN + enabled: true
  Sentrace.init({
    dsn: "https://pub123@errors.example.com/sentrace/9",
    enabled: true,
    autoInstrumentBrowser: false,
    railsIntegration: false,
    ignoreErrors: [/IgnoredNoise/],
    beforeSend(ev) {
      return ev.tags?.drop === "true" ? null : ev;
    },
    transport: mem.factory
  });
  assert.equal(Sentrace.isEnabled(), true);

  const acceptedId = Sentrace.captureException(new Error("Accepted failure"));
  assert.match(acceptedId, /^[0-9a-f]{32}$/);
  assert.equal(Sentrace.lastEventId(), acceptedId);

  // Subsequent dropped/ignored events MUST NOT overwrite lastEventId()
  Sentrace.captureException(new Error("IgnoredNoise warning"));
  Sentrace.captureMessage("Dropped by beforeSend", { tags: { drop: "true" } });
  assert.equal(Sentrace.lastEventId(), acceptedId);
  assert.equal(mem.envelopes.length, 1);

  await Sentrace.close();
  assert.equal(Sentrace.isEnabled(), false);
  assert.equal(Sentrace.lastEventId(), undefined);
});

test("Calling Sentrace.init() multiple times updates options, preserves globalScope, and survives third-party fetch/XHR/history wrappers without duplicates", async () => {
  Sentrace.resetClient();
  const prevWin = globalThis.window;
  const prevDoc = globalThis.document;
  const prevFetch = globalThis.fetch;
  const prevXhr = globalThis.XMLHttpRequest;

  const { fakeWindow, fakeDocument } = createFakeBrowserEnv(
    {},
    "https://app.example.com/dashboard"
  );
  const memA = createMemoryTransport();
  const memB = createMemoryTransport();

  class FakeXhr {
    constructor() {
      this.status = 200;
      this.listeners = new Map();
    }
    open(_method, _url) {}
    send(_body) {
      for (const fn of this.listeners.get("loadend") ?? []) {
        fn();
      }
    }
    addEventListener(type, fn) {
      const arr = this.listeners.get(type) ?? [];
      arr.push(fn);
      this.listeners.set(type, arr);
    }
    getResponseHeader() {
      return null;
    }
  }

  try {
    globalThis.window = fakeWindow;
    globalThis.document = fakeDocument;
    globalThis.XMLHttpRequest = FakeXhr;
    globalThis.fetch = async () => ({ status: 200, headers: { get: () => null } });

    // Pre-init scope data must also survive first init()
    Sentrace.setTag("boot_phase", "early");

    const clientARef = (() => {
      Sentrace.init({
        dsn: "https://pub_a@errors.example.com/sentrace/1",
        release: "v1",
        transport: memA.factory
      });
      return Sentrace.getClient();
    })();
    assert.equal(clientARef.isEnabled(), true);

    Sentrace.setUser({ id: "u-42", email: "dev@example.com" });

    // Simulate third-party libraries wrapping fetch, XMLHttpRequest, and history.pushState AFTER first init()
    let thirdPartyFetchCalls = 0;
    const fetchAfterInit1 = globalThis.fetch;
    globalThis.fetch = function thirdPartyFetch(...args) {
      thirdPartyFetchCalls += 1;
      return fetchAfterInit1.apply(this, args);
    };

    let thirdPartyXhrSendCalls = 0;
    const xhrSendAfterInit1 = FakeXhr.prototype.send;
    FakeXhr.prototype.send = function thirdPartyXhrSend(...args) {
      thirdPartyXhrSendCalls += 1;
      return xhrSendAfterInit1.apply(this, args);
    };

    let thirdPartyPushStateCalls = 0;
    const pushStateAfterInit1 = fakeWindow.history.pushState;
    fakeWindow.history.pushState = function thirdPartyPushState(...args) {
      thirdPartyPushStateCalls += 1;
      return pushStateAfterInit1.apply(this, args);
    };

    // Second Sentrace.init() after async runtime config arrives
    Sentrace.init({
      dsn: "https://pub_b@errors.example.com/sentrace/2",
      release: "v2",
      transport: memB.factory
    });

    assert.equal(clientARef.isEnabled(), false);
    assert.equal(Sentrace.isEnabled(), true);

    await globalThis.fetch("https://app.example.com/api/ping?token=secret1");
    const xhr = new FakeXhr();
    xhr.open("GET", "https://app.example.com/api/xhr-check");
    xhr.send();
    fakeWindow.history.pushState({}, "", "/settings");
    fakeWindow.dispatch("error", { error: new Error("Boom after re-init") });

    // Third-party wrappers must remain intact and execute
    assert.equal(thirdPartyFetchCalls, 1);
    assert.equal(thirdPartyXhrSendCalls, 1);
    assert.equal(thirdPartyPushStateCalls, 1);

    // Zero events sent to first client; exactly one event sent to second client
    assert.equal(memA.envelopes.length, 0);
    assert.equal(memB.envelopes.length, 1);

    const ev = memB.envelopes[0].event;
    assert.equal(memB.envelopes[0].header.dsn, "https://pub_b@errors.example.com/sentrace/2");
    assert.equal(ev.release, "v2");
    assert.equal(ev.user.id, "u-42");
    assert.equal(ev.tags.boot_phase, "early");
    // Exactly 1 fetch + 1 xhr + 1 navigation breadcrumb (no duplicate instrumentation!)
    assert.equal(ev.breadcrumbs.values.length, 3);
    assert.deepEqual(
      ev.breadcrumbs.values.map((b) => b.category),
      ["fetch", "xhr", "navigation"]
    );
    assert.equal(ev.breadcrumbs.values[0].data.url, "https://app.example.com/api/ping?token=[REDACTED]");
    assert.equal(Sentrace.lastEventId(), ev.event_id);

    await Sentrace.close();
  } finally {
    globalThis.window = prevWin;
    globalThis.document = prevDoc;
    globalThis.fetch = prevFetch;
    globalThis.XMLHttpRequest = prevXhr;
    Sentrace.resetClient();
  }
});

test("Scope rejects prototype-pollution keys and Rails/browser instrumentation rejects unsafe X-Request-Id values", async () => {
  Sentrace.resetClient();
  const prevWin = globalThis.window;
  const prevDoc = globalThis.document;
  const prevFetch = globalThis.fetch;

  const { fakeWindow, fakeDocument } = createFakeBrowserEnv({
    "sentrace-dsn": "https://pub_sec@shop.example.com/sentrace/5",
    "sentrace-request-id": "bad request id with spaces\r\ninjected"
  });
  const mem = createMemoryTransport();

  try {
    globalThis.window = fakeWindow;
    globalThis.document = fakeDocument;
    globalThis.fetch = async () => ({
      status: 500,
      headers: {
        get: (k) => (k.toLowerCase() === "x-request-id" ? "unsafe\nheader value!" : null)
      }
    });

    Sentrace.init({ transport: mem.factory });
    Sentrace.setTag("__proto__", "polluted");
    Sentrace.setTag("constructor", "polluted");
    Sentrace.setExtra("__proto__", { polluted: true });
    Sentrace.setContext("__proto__", { polluted: true });
    Sentrace.setContext("checkout", JSON.parse('{"__proto__":{"polluted":true},"step":"pay"}'));

    await globalThis.fetch("https://shop.example.com/orders", { method: "POST" });
    Sentrace.captureException(new Error("Security check"));

    assert.equal(({}).polluted, undefined);
    assert.equal(mem.envelopes.length, 1);
    const ev = mem.envelopes[0].event;
    assert.equal(ev.tags?.request_id, undefined);
    assert.equal(Object.prototype.hasOwnProperty.call(ev.tags ?? {}, "__proto__"), false);
    assert.equal(Object.prototype.hasOwnProperty.call(ev.tags ?? {}, "constructor"), false);
    assert.equal(ev.contexts.checkout.step, "pay");
    assert.equal(ev.breadcrumbs.values[0].data.request_id, undefined);

    await Sentrace.close();
  } finally {
    globalThis.window = prevWin;
    globalThis.document = prevDoc;
    globalThis.fetch = prevFetch;
    Sentrace.resetClient();
  }
});

test("Async withScope retains isolated scope across await boundaries and cross-origin fetch errors do not overwrite request_id", async () => {
  Sentrace.resetClient();
  const prevWin = globalThis.window;
  const prevDoc = globalThis.document;
  const prevFetch = globalThis.fetch;

  const { fakeWindow, fakeDocument } = createFakeBrowserEnv({
    "sentrace-dsn": "https://pub_origin@shop.example.com/sentrace/5",
    "sentrace-request-id": "req-trusted-same-origin"
  });
  const mem = createMemoryTransport();

  try {
    globalThis.window = fakeWindow;
    globalThis.document = fakeDocument;
    globalThis.fetch = async (url) => {
      if (String(url).includes("evil-third-party.example")) {
        return {
          status: 500,
          headers: {
            get: (k) => (k.toLowerCase() === "x-request-id" ? "req-spoofed-cross-origin" : null)
          }
        };
      }
      return { status: 200, headers: { get: () => null } };
    };

    Sentrace.init({ transport: mem.factory });

    // Cross-origin 500 response MUST NOT overwrite global scope's trusted Rails request_id
    await globalThis.fetch("https://evil-third-party.example/widget");

    await Sentrace.withScope(async (scope) => {
      scope.setTag("async_flow", "checkout");
      await Promise.resolve();
      Sentrace.captureException(new Error("Async failure after await"));
    });

    Sentrace.captureMessage("Outside async scope");

    assert.equal(mem.envelopes.length, 2);
    assert.equal(mem.envelopes[0].event.tags.request_id, "req-trusted-same-origin");
    assert.equal(mem.envelopes[0].event.tags.async_flow, "checkout");
    assert.equal(mem.envelopes[1].event.tags.async_flow, undefined);

    await Sentrace.close();
  } finally {
    globalThis.window = prevWin;
    globalThis.document = prevDoc;
    globalThis.fetch = prevFetch;
    Sentrace.resetClient();
  }
});

test("window.onerror scrubs fallbackFrame filename and stack frames honor custom redactFields", async () => {
  Sentrace.resetClient();
  const prevWin = globalThis.window;
  const prevDoc = globalThis.document;
  const { fakeWindow, fakeDocument } = createFakeBrowserEnv({});
  const mem = createMemoryTransport();

  try {
    globalThis.window = fakeWindow;
    globalThis.document = fakeDocument;

    Sentrace.init({
      dsn: "https://pub_err@shop.example.com/sentrace/7",
      railsIntegration: false,
      redactFields: ["custom_secret"],
      transport: mem.factory
    });

    // window.onerror with no Error object uses fallbackFrame.filename, which MUST be scrubbed
    fakeWindow.dispatch("error", {
      message: "Script error.",
      filename: "https://shop.example.com/embed.js?custom_secret=topsecret&X-Amz-Signature=sig123&ok=1#access_token=frag",
      lineno: 12,
      colno: 4
    });

    const errWithStack = new Error("Stack redact check");
    errWithStack.stack = [
      "Error: Stack redact check",
      "    at run (https://shop.example.com/app.js?custom_secret=stacksec&ok=2:5:10)"
    ].join("\n");
    Sentrace.captureException(errWithStack);

    assert.equal(mem.envelopes.length, 2);
    const onErrorFrame = mem.envelopes[0].event.exception.values[0].stacktrace.frames[0];
    assert.equal(
      onErrorFrame.filename,
      "https://shop.example.com/embed.js?custom_secret=[REDACTED]&X-Amz-Signature=[REDACTED]&ok=1"
    );

    const stackFrame = mem.envelopes[1].event.exception.values[0].stacktrace.frames[0];
    assert.equal(stackFrame.filename, "https://shop.example.com/app.js?custom_secret=[REDACTED]&ok=2");

    await Sentrace.close();
  } finally {
    globalThis.window = prevWin;
    globalThis.document = prevDoc;
    Sentrace.resetClient();
  }
});
