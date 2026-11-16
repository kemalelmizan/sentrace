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
