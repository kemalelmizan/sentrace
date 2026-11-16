(function (root) {
  "use strict";
  // --- dsn.ts ---
  const VERSION = "0.1.0";
  const SDK_NAME = "sentrace.javascript.browser";
  const SDK_CLIENT = `sentrace-js/${VERSION}`;

  const DEFAULT_SENSITIVE_QUERY_KEYS = [
    "password",
    "passwd",
    "secret",
    "token",
    "access_token",
    "refresh_token",
    "id_token",
    "api_key",
    "apikey",
    "authorization",
    "cookie",
    "session",
    "session_id",
    "credit_card",
    "card_number",
    "cvv",
    "cvc",
    "sentry_secret"
  ];

  function parseDsn(rawDsn                           )                   {
    if (!rawDsn || typeof rawDsn !== "string") {
      return null;
    }

    const trimmed = rawDsn.trim();
    if (!trimmed) {
      return null;
    }

    let uri     ;
    try {
      uri = new URL(trimmed);
    } catch {
      return null;
    }

    const protocol = uri.protocol === "https:" ? "https" : uri.protocol === "http:" ? "http" : null;
    if (!protocol || !uri.hostname || !uri.username) {
      return null;
    }

    const segments = uri.pathname.split("/").filter(Boolean);
    if (segments.length === 0) {
      return null;
    }

    const projectId = segments.pop() ;
    const pathPrefix = segments.length > 0 ? `/${segments.join("/")}` : "";

    return {
      protocol,
      publicKey: decodeURIComponent(uri.username),
      host: uri.hostname,
      port: uri.port || undefined,
      pathPrefix,
      projectId
    };
  }

  function formatPublicDsn(dsn           )         {
    const authority = dsn.port ? `${dsn.host}:${dsn.port}` : dsn.host;
    return `${dsn.protocol}://${encodeURIComponent(dsn.publicKey)}@${authority}${dsn.pathPrefix}/${dsn.projectId}`;
  }

  function buildEnvelopeEndpoint(dsn           )         {
    const authority = dsn.port ? `${dsn.host}:${dsn.port}` : dsn.host;
    const query = `sentry_key=${encodeURIComponent(dsn.publicKey)}&sentry_version=7&sentry_client=${encodeURIComponent(SDK_CLIENT)}`;
    return `${dsn.protocol}://${authority}${dsn.pathPrefix}/api/${dsn.projectId}/envelope?${query}`;
  }

  function scrubUrl(rawUrl                    , extraRedactFields           = [])                     {
    if (!rawUrl || typeof rawUrl !== "string") {
      return undefined;
    }

    const trimmed = rawUrl.trim();
    if (!trimmed) {
      return undefined;
    }

    const redactPatterns = [
      ...DEFAULT_SENSITIVE_QUERY_KEYS,
      ...extraRedactFields.map((f) => String(f).toLowerCase())
    ];

    const isSensitive = (key        )          => {
      const lower = key.toLowerCase();
      return redactPatterns.some((term) => lower.includes(term));
    };

    try {
      const base = "http://sentrace-relative.local";
      const isRelative = !/^[a-zA-Z][a-zA-Z\d+\-.]*:\/\//.test(trimmed);
      const parsed = isRelative ? new URL(trimmed, base) : new URL(trimmed);

      parsed.username = "";
      parsed.password = "";

      if (parsed.search) {
        const scrubbedParams = new URLSearchParams();
        for (const [key, val] of parsed.searchParams.entries()) {
          scrubbedParams.append(key, isSensitive(key) ? "[REDACTED]" : val);
        }
        // Preserve literal [REDACTED] readability instead of %5BREDACTED%5D where safe
        const serialized = scrubbedParams.toString().replace(/%5BREDACTED%5D/g, "[REDACTED]");
        parsed.search = serialized ? `?${serialized}` : "";
      }

      if (isRelative) {
        return `${parsed.pathname}${parsed.search}${parsed.hash}`;
      }
      return parsed.toString();
    } catch {
      return trimmed.split("?")[0]?.replace(/\/\/[^/@]+@/, "//") ?? trimmed;
    }
  }

  // --- stacktrace.ts ---
  // V8 / Chromium / Edge / Node:
  //   at fnName (https://app.example.com/assets/app.js:12:34)
  //   at async Object.submit [as click] (https://app.example.com/assets/app.js:12:34)
  //   at https://app.example.com/assets/app.js:12:34
  const V8_FRAME_WITH_PARENS =
    /^\s*at\s+(?:async\s+)?(?:new\s+)?(.+?)\s+\((?:eval at [^\s]+\s+\()?(.+?):(\d+):(\d+)\)?\)\s*$/;
  const V8_BARE_FRAME = /^\s*at\s+(?:async\s+)?(.+?):(\d+):(\d+)\s*$/;

  // Firefox / SpiderMonkey & Safari / JavaScriptCore:
  //   submitOrder@https://app.example.com/assets/app.js:12:34
  //   @https://app.example.com/assets/app.js:12:34
  //   global code@https://app.example.com/assets/app.js:1:10
  const GECKO_WEBKIT_FRAME = /^\s*(?:([^@]*)@)?(.+?):(\d+):(\d+)\s*$/;

  const NON_APP_URL_PATTERNS = [
    "/node_modules/",
    "/vendor/",
    "chrome-extension://",
    "moz-extension://",
    "safari-extension://",
    "safari-web-extension://",
    "webkit-masked-url://",
    "cdn.jsdelivr.net",
    "unpkg.com",
    "ga.jspm.io",
    "cdnjs.cloudflare.com",
    "sentrace.browser.js",
    "/sentrace/dist/"
  ];

  function isInAppFilename(filename                    )          {
    if (!filename) {
      return false;
    }
    if (filename === "<anonymous>" || filename === "[native code]" || filename.startsWith("node:")) {
      return false;
    }
    const lower = filename.toLowerCase();
    return !NON_APP_URL_PATTERNS.some((pattern) => lower.includes(pattern));
  }

  function cleanFunctionName(raw                    )         {
    if (!raw) {
      return "?";
    }
    const cleaned = raw
      .replace(/\s+\[as [^\]]+\]$/, "")
      .replace(/^async\*/, "")
      .trim();
    if (!cleaned || cleaned === "<anonymous>" || cleaned === "global code" || cleaned === "module code") {
      return "?";
    }
    return cleaned;
  }

  function parseStackLine(line        )                    {
    const trimmed = line.trim();
    if (!trimmed || trimmed.includes("[native code]")) {
      return null;
    }

    let match = V8_FRAME_WITH_PARENS.exec(trimmed);
    if (match) {
      const filename = match[2] .trim();
      return {
        filename,
        function: cleanFunctionName(match[1]),
        lineno: Number.parseInt(match[3] , 10),
        colno: Number.parseInt(match[4] , 10),
        in_app: isInAppFilename(filename)
      };
    }

    match = V8_BARE_FRAME.exec(trimmed);
    if (match) {
      const filename = match[1] .trim();
      return {
        filename,
        function: "?",
        lineno: Number.parseInt(match[2] , 10),
        colno: Number.parseInt(match[3] , 10),
        in_app: isInAppFilename(filename)
      };
    }

    if (!trimmed.startsWith("at ")) {
      match = GECKO_WEBKIT_FRAME.exec(trimmed);
      if (match) {
        const filename = match[2] .trim();
        if (filename.includes("/") || filename.includes(".") || filename.startsWith("http")) {
          return {
            filename,
            function: cleanFunctionName(match[1]),
            lineno: Number.parseInt(match[3] , 10),
            colno: Number.parseInt(match[4] , 10),
            in_app: isInAppFilename(filename)
          };
        }
      }
    }

    return null;
  }

  /**
   * Parses JavaScript Error.stack strings (V8, Firefox, Safari) into Sentry v7 stack frames
   * ordered from oldest caller frame to newest crash site frame.
   */
  function parseStackFrames(stack                    , maxFrames = 50)               {
    if (!stack || typeof stack !== "string") {
      return [];
    }

    const newestFirst               = [];
    for (const line of stack.split(/\r?\n/)) {
      const frame = parseStackLine(line);
      if (frame) {
        newestFirst.push(frame);
      }
    }

    const oldestFirst = newestFirst.reverse();
    if (oldestFirst.length > maxFrames) {
      return oldestFirst.slice(oldestFirst.length - maxFrames);
    }
    return oldestFirst;
  }

  function normalizeSingleError(
    err         ,
    maxFrames        ,
    handled         ,
    mechanismType
  )                       {
    if (err instanceof Error) {
      const frames = parseStackFrames(err.stack, maxFrames);
      return {
        type: err.name || err.constructor?.name || "Error",
        value: err.message || String(err),
        ...(frames.length > 0 ? { stacktrace: { frames } } : {}),
        mechanism: { type: mechanismType, handled }
      };
    }

    if (typeof err === "object" && err !== null) {
      const obj = err                           ;
      const typeName =
        (typeof obj.name === "string" && obj.name) ||
        (typeof obj.constructor?.name === "string" && obj.constructor.name !== "Object"
          ? obj.constructor.name
          : "Error");
      const message =
        typeof obj.message === "string"
          ? obj.message
          : (() => {
              try {
                return JSON.stringify(obj);
              } catch {
                return String(obj);
              }
            })();
      const frames = typeof obj.stack === "string" ? parseStackFrames(obj.stack, maxFrames) : [];
      return {
        type: typeName,
        value: message,
        ...(frames.length > 0 ? { stacktrace: { frames } } : {}),
        mechanism: { type: mechanismType, handled }
      };
    }

    return {
      type: "Error",
      value: String(err),
      mechanism: { type: mechanismType, handled }
    };
  }

  /**
   * Extracts chained exceptions (`error.cause`) ordered from innermost cause to outermost error,
   * matching Sentry's `exception.values` specification and Sentrace's `EventNormalizer`.
   */
  function extractExceptionChain(
    error         ,
    maxFrames = 50,
    handled = true,
    mechanismType = "generic",
    syntheticException
  )                         {
    const chain                         = [];
    const seen = new Set         ();
    let current          = error;
    let depth = 0;

    while (current !== undefined && current !== null && depth < 5 && !seen.has(current)) {
      seen.add(current);
      const entry = normalizeSingleError(current, maxFrames, handled, mechanismType);
      if (depth === 0 && !entry.stacktrace && syntheticException?.stack) {
        const fallbackFrames = parseStackFrames(syntheticException.stack, maxFrames);
        if (fallbackFrames.length > 0) {
          entry.stacktrace = { frames: fallbackFrames };
        }
      }
      chain.push(entry);

      if (typeof current === "object" && current !== null && "cause" in current) {
        current = (current                       ).cause;
        depth += 1;
      } else {
        break;
      }
    }

    if (chain.length === 0) {
      chain.push(normalizeSingleError(error, maxFrames, handled, mechanismType));
    }

    return chain.reverse();
  }

  // --- scope.ts ---
  class Scope                      {
            tags                         = {};
            user              = null;
            contexts                                          = {};
            extra                          = {};
            breadcrumbs               = [];
            fingerprint                      ;
            level                           ;

    setTag(key        , value                           )       {
      this.tags[String(key)] = String(value);
      return this;
    }

    setTags(tags                                           )       {
      for (const [k, v] of Object.entries(tags)) {
        if (v !== undefined && v !== null) {
          this.tags[k] = String(v);
        }
      }
      return this;
    }

    getTag(key        )                     {
      return this.tags[key];
    }

    setUser(user             )       {
      this.user = user ? { ...user } : null;
      return this;
    }

    setContext(name        , context                                )       {
      if (context === null) {
        delete this.contexts[name];
      } else {
        this.contexts[name] = { ...context };
      }
      return this;
    }

    setExtra(key        , extra         )       {
      this.extra[key] = extra;
      return this;
    }

    setExtras(extras                         )       {
      Object.assign(this.extra, extras);
      return this;
    }

    setLevel(level               )       {
      this.level = level;
      return this;
    }

    setFingerprint(fingerprint          )       {
      this.fingerprint = [...fingerprint];
      return this;
    }

    addBreadcrumb(breadcrumb            , maxBreadcrumbs = 20)       {
      if (maxBreadcrumbs <= 0) {
        return this;
      }

      const normalized             = {
        ...breadcrumb,
        timestamp: breadcrumb.timestamp ?? new Date().toISOString()
      };

      this.breadcrumbs.push(normalized);
      if (this.breadcrumbs.length > maxBreadcrumbs) {
        this.breadcrumbs.splice(0, this.breadcrumbs.length - maxBreadcrumbs);
      }
      return this;
    }

    clearBreadcrumbs()       {
      this.breadcrumbs = [];
      return this;
    }

    clear()       {
      this.tags = {};
      this.user = null;
      this.contexts = {};
      this.extra = {};
      this.breadcrumbs = [];
      this.fingerprint = undefined;
      this.level = undefined;
      return this;
    }

    clone()        {
      const next = new Scope();
      next.tags = { ...this.tags };
      next.user = this.user ? { ...this.user } : null;
      next.contexts = {};
      for (const [k, v] of Object.entries(this.contexts)) {
        next.contexts[k] = { ...v };
      }
      next.extra = { ...this.extra };
      next.breadcrumbs = this.breadcrumbs.map((b) => ({
        ...b,
        ...(b.data ? { data: { ...b.data } } : {})
      }));
      next.fingerprint = this.fingerprint ? [...this.fingerprint] : undefined;
      next.level = this.level;
      return next;
    }

    applyCaptureContext(context                 )       {
      if (!context) {
        return this;
      }

      if (typeof context === "function") {
        context(this);
        return this;
      }

      if (context.level) {
        this.setLevel(context.level);
      }
      if (context.tags) {
        this.setTags(context.tags);
      }
      if (context.extra) {
        this.setExtras(context.extra);
      }
      if (context.contexts) {
        for (const [name, val] of Object.entries(context.contexts)) {
          this.setContext(name, val);
        }
      }
      if (context.user !== undefined) {
        this.setUser(context.user);
      }
      if (context.fingerprint) {
        this.setFingerprint(context.fingerprint);
      }
      return this;
    }

    applyToEvent(event             , maxBreadcrumbs        )              {
      const mergedTags = { ...this.tags, ...(event.tags ?? {}) };
      if (Object.keys(mergedTags).length > 0) {
        event.tags = mergedTags;
      }

      const mergedExtra = { ...this.extra, ...(event.extra ?? {}) };
      if (Object.keys(mergedExtra).length > 0) {
        event.extra = mergedExtra;
      }

      const mergedContexts                                          = {};
      for (const [k, v] of Object.entries(this.contexts)) {
        mergedContexts[k] = { ...v };
      }
      if (event.contexts) {
        for (const [k, v] of Object.entries(event.contexts)) {
          mergedContexts[k] = { ...(mergedContexts[k] ?? {}), ...v };
        }
      }
      if (Object.keys(mergedContexts).length > 0) {
        event.contexts = mergedContexts;
      }

      if (event.user === undefined && this.user) {
        event.user = { ...this.user };
      }

      if (!event.level && this.level) {
        event.level = this.level;
      } else if (!event.level) {
        event.level = "error";
      }

      if (!event.fingerprint && this.fingerprint && this.fingerprint.length > 0) {
        event.fingerprint = [...this.fingerprint];
      }

      const existingCrumbs = event.breadcrumbs?.values ?? [];
      const combinedCrumbs = [...this.breadcrumbs, ...existingCrumbs].slice(-Math.max(0, maxBreadcrumbs));
      if (combinedCrumbs.length > 0) {
        event.breadcrumbs = { values: combinedCrumbs };
      }

      return event;
    }
  }

  // --- envelope.ts ---
  function generateEventId()         {
    const g = globalThis

     ;

    if (g.crypto?.randomUUID) {
      return g.crypto.randomUUID().replace(/-/g, "").toLowerCase();
    }

    if (g.crypto?.getRandomValues) {
      const bytes = g.crypto.getRandomValues(new Uint8Array(16));
      let hex = "";
      for (let i = 0; i < bytes.length; i += 1) {
        hex += bytes[i] .toString(16).padStart(2, "0");
      }
      return hex;
    }

    let fallback = "";
    for (let i = 0; i < 32; i += 1) {
      fallback += Math.floor(Math.random() * 16).toString(16);
    }
    return fallback;
  }

  /**
   * Serializes a normalized `SentryEvent` into a standard 3-line Sentry v7 Envelope.
   */
  function serializeEnvelope(event             , dsn           )         {
    const envelopeHeader = JSON.stringify({
      event_id: event.event_id,
      sent_at: new Date().toISOString(),
      dsn: formatPublicDsn(dsn),
      sdk: {
        name: SDK_NAME,
        version: VERSION
      }
    });

    const payload = JSON.stringify(event);
    const byteLength =
      typeof TextEncoder !== "undefined" ? new TextEncoder().encode(payload).byteLength : payload.length;
    const itemHeader = JSON.stringify({
      type: "event",
      content_type: "application/json",
      length: byteLength
    });

    return `${envelopeHeader}\n${itemHeader}\n${payload}\n`;
  }

  // --- transport.ts ---
  const SENTRACE_INTERNAL_FETCH_FLAG = "__sentraceInternalRequest";

  function createBrowserTransport(endpointUrl        )            {
    const pending = new Set                  ();

    const sendViaBeacon = (envelope        )          => {
      try {
        const nav = (globalThis                                                                             ).navigator;
        if (nav && typeof nav.sendBeacon === "function") {
          return nav.sendBeacon(endpointUrl, envelope);
        }
      } catch {
        // Ignore sendBeacon errors
      }
      return false;
    };

    const send = (envelope        )                                        => {
      const doc = (globalThis                                               ).document;
      if (doc?.visibilityState === "hidden" && sendViaBeacon(envelope)) {
        return Promise.resolve({ statusCode: 200 });
      }

      const fetchFn = (globalThis                            ).fetch;
      if (typeof fetchFn !== "function") {
        const ok = sendViaBeacon(envelope);
        return Promise.resolve({ statusCode: ok ? 200 : 0 });
      }

      const initOptions                                                             = {
        method: "POST",
        body: envelope,
        headers: {
          "Content-Type": "text/plain;charset=UTF-8"
        },
        keepalive: true,
        credentials: "omit"
      };
      Object.defineProperty(initOptions, SENTRACE_INTERNAL_FETCH_FLAG, {
        value: true,
        enumerable: false
      });

      const requestPromise = fetchFn(endpointUrl, initOptions)
        .then((res) => ({ statusCode: res.status }))
        .catch(() => {
          const fallbackOk = sendViaBeacon(envelope);
          return { statusCode: fallbackOk ? 200 : 0 };
        });

      pending.add(requestPromise);
      void requestPromise.finally(() => {
        pending.delete(requestPromise);
      });

      return requestPromise;
    };

    const flush = async (timeout = 2000)                   => {
      if (pending.size === 0) {
        return true;
      }

      const allDone = Promise.allSettled(Array.from(pending)).then(() => true);
      if (timeout <= 0) {
        return allDone;
      }

      let timer                                           ;
      const timedOut = new Promise         ((resolve) => {
        timer = setTimeout(() => resolve(false), timeout);
      });

      const result = await Promise.race([allDone, timedOut]);
      if (timer !== undefined) {
        clearTimeout(timer);
      }
      return result;
    };

    return {
      send,
      sendOnExit: sendViaBeacon,
      flush
    };
  }

  // --- browser.ts ---
  function describeElement(target         )         {
    if (!target || typeof target !== "object") {
      return "<unknown>";
    }
    const el = target

     ;
    const tag = typeof el.tagName === "string" ? el.tagName.toLowerCase() : "element";
    const idPart = typeof el.id === "string" && el.id ? `#${el.id}` : "";
    const classPart =
      typeof el.className === "string" && el.className.trim()
        ? `.${el.className
            .trim()
            .split(/\s+/)
            .slice(0, 3)
            .join(".")}`
        : "";
    const typeAttr = typeof el.getAttribute === "function" ? el.getAttribute("type") : null;
    const attrPart = typeAttr ? `[type="${typeAttr}"]` : "";
    return `${tag}${idPart}${classPart}${attrPart}`;
  }

  function isInternalEndpoint(url        , endpointUrl               )          {
    if (!endpointUrl || !url) {
      return false;
    }
    const baseEndpoint = endpointUrl.split("?")[0] ;
    return url.startsWith(baseEndpoint);
  }

  function installBrowserInstrumentation(hooks                             )             {
    const cleanups                    = [];
    const g = globalThis                           ;
    const win = (g.window ?? g)

     ;
    const doc = g.document

                 ;

    if (typeof win?.addEventListener === "function" && typeof win?.removeEventListener === "function") {
      const errorListener = (rawEvent         )       => {
        const ev = rawEvent

         ;
        const err = ev?.error ?? new Error(ev?.message || "Uncaught window error");
        const fallbackFrame                         =
          ev?.filename
            ? {
                filename: ev.filename,
                function: "?",
                lineno: typeof ev.lineno === "number" ? ev.lineno : undefined,
                colno: typeof ev.colno === "number" ? ev.colno : undefined,
                in_app: true
              }
            : undefined;

        hooks.onError(err, {
          handled: false,
          mechanismType: "onerror",
          fallbackFrame
        });
      };

      const rejectionListener = (rawEvent         )       => {
        const ev = rawEvent                        ;
        const reason = ev && "reason" in ev ? ev.reason : new Error("Unhandled Promise rejection");
        hooks.onError(reason ?? new Error("Unhandled Promise rejection"), {
          handled: false,
          mechanismType: "onunhandledrejection"
        });
      };

      win.addEventListener("error", errorListener);
      win.addEventListener("unhandledrejection", rejectionListener);
      cleanups.push(() => {
        win.removeEventListener?.("error", errorListener);
        win.removeEventListener?.("unhandledrejection", rejectionListener);
      });

      let lastHref = win.location?.href;
      const popstateListener = ()       => {
        const nextHref = win.location?.href;
        hooks.onBreadcrumb({
          type: "navigation",
          category: "navigation",
          level: "info",
          data: {
            from: scrubUrl(lastHref, hooks.redactFields),
            to: scrubUrl(nextHref, hooks.redactFields)
          }
        });
        lastHref = nextHref;
      };
      win.addEventListener("popstate", popstateListener);
      cleanups.push(() => {
        win.removeEventListener?.("popstate", popstateListener);
      });

      if (win.history) {
        const historyObj = win.history;
        for (const methodName of ["pushState", "replaceState"]         ) {
          const original = historyObj[methodName];
          if (typeof original === "function") {
            historyObj[methodName] = function patchedHistory(...args           )          {
              const prev = lastHref ?? win.location?.href;
              const result = original.apply(this, args);
              let nextUrl = win.location?.href;
              if ((!nextUrl || nextUrl === prev) && args[2] !== undefined && args[2] !== null) {
                try {
                  nextUrl = prev ? new URL(String(args[2]), prev).toString() : String(args[2]);
                } catch {
                  nextUrl = String(args[2]);
                }
              }
              lastHref = nextUrl;
              hooks.onBreadcrumb({
                type: "navigation",
                category: "navigation",
                level: "info",
                data: {
                  from: scrubUrl(prev, hooks.redactFields),
                  to: scrubUrl(nextUrl, hooks.redactFields)
                }
              });
              return result;
            };
            cleanups.push(() => {
              historyObj[methodName] = original;
            });
          }
        }
      }
    }

    if (doc && typeof doc.addEventListener === "function" && typeof doc.removeEventListener === "function") {
      const clickListener = (rawEvent         )       => {
        const ev = rawEvent                        ;
        hooks.onBreadcrumb({
          type: "ui",
          category: "ui.click",
          level: "info",
          message: describeElement(ev?.target)
        });
      };
      doc.addEventListener("click", clickListener, true);
      cleanups.push(() => {
        doc.removeEventListener?.("click", clickListener, true);
      });
    }

    if (typeof g.fetch === "function") {
      const originalFetch = g.fetch                ;
      const wrappedFetch = function sentraceFetch(
        input                   ,
        init
      )                    {
        if (init && init[SENTRACE_INTERNAL_FETCH_FLAG]) {
          return originalFetch.call(globalThis, input, init);
        }

        const rawUrl =
          typeof input === "string"
            ? input
            : input instanceof URL
              ? input.toString()
              : typeof (input                    )?.url === "string"
                ? (input                   ).url
                : "";

        if (isInternalEndpoint(rawUrl, hooks.endpointUrl)) {
          return originalFetch.call(globalThis, input, init);
        }

        const method = (
          init?.method ??
          (typeof (input                       )?.method === "string" ? (input                      ).method : "GET")
        ).toUpperCase();
        const safeUrl = scrubUrl(rawUrl, hooks.redactFields);

        return originalFetch.call(globalThis, input, init).then(
          (response) => {
            const requestId =
              typeof response?.headers?.get === "function"
                ? response.headers.get("x-request-id") ?? undefined
                : undefined;
            const status = typeof response?.status === "number" ? response.status : undefined;

            if (requestId && status !== undefined && status >= 400) {
              hooks.onCorrelatedRequestId(requestId);
            }

            hooks.onBreadcrumb({
              type: "http",
              category: "fetch",
              level: status !== undefined && status >= 400 ? "warning" : "info",
              data: {
                method,
                url: safeUrl,
                ...(status !== undefined ? { status_code: status } : {}),
                ...(requestId ? { request_id: requestId } : {})
              }
            });
            return response;
          },
          (networkErr         ) => {
            hooks.onBreadcrumb({
              type: "http",
              category: "fetch",
              level: "error",
              data: {
                method,
                url: safeUrl,
                error: networkErr instanceof Error ? networkErr.name : "NetworkError"
              }
            });
            throw networkErr;
          }
        );
      };

      g.fetch = wrappedFetch;
      cleanups.push(() => {
        if (g.fetch === wrappedFetch) {
          g.fetch = originalFetch;
        }
      });
    }

    const XhrCtor = g.XMLHttpRequest

                 ;

    if (XhrCtor?.prototype && typeof XhrCtor.prototype.open === "function" && typeof XhrCtor.prototype.send === "function") {
      const proto = XhrCtor.prototype;
      const origOpen = proto.open ;
      const origSend = proto.send ;

      proto.open = function sentraceXhrOpen(

        method        ,
        url              ,
        ...rest
      )          {
        this.__sentraceXhrMeta = {
          method: String(method || "GET").toUpperCase(),
          url: String(url || "")
        };
        return origOpen.call(this, method, url, ...rest);
      };

      proto.send = function sentraceXhrSend(                               body          )          {
        const meta = this.__sentraceXhrMeta                                               ;
        if (meta && !isInternalEndpoint(meta.url, hooks.endpointUrl)) {
          const onLoadEnd = ()       => {
            const status = typeof this.status === "number" ? this.status : undefined;
            const getHeader = this.getResponseHeader                                                 ;
            const requestId =
              typeof getHeader === "function" ? getHeader.call(this, "x-request-id") ?? undefined : undefined;

            if (requestId && status !== undefined && status >= 400) {
              hooks.onCorrelatedRequestId(requestId);
            }

            hooks.onBreadcrumb({
              type: "http",
              category: "xhr",
              level: status !== undefined && status >= 400 ? "warning" : "info",
              data: {
                method: meta.method,
                url: scrubUrl(meta.url, hooks.redactFields),
                ...(status !== undefined ? { status_code: status } : {}),
                ...(requestId ? { request_id: requestId } : {})
              }
            });
          };

          const addListener = this.addEventListener                                                        ;
          if (typeof addListener === "function") {
            addListener.call(this, "loadend", onLoadEnd);
          }
        }
        return origSend.call(this, body);
      };

      cleanups.push(() => {
        proto.open = origOpen;
        proto.send = origSend;
      });
    }

    return () => {
      for (const fn of cleanups.splice(0)) {
        try {
          fn();
        } catch {
          // Ignore teardown errors
        }
      }
    };
  }

  // --- rails.ts ---
  function readMetaTagContent(doc                               , metaName        )                     {
    if (!doc) {
      return undefined;
    }

    if (typeof doc.querySelector === "function") {
      const el = doc.querySelector(`meta[name="${metaName}"]`);
      if (el) {
        const val = (typeof el.getAttribute === "function" ? el.getAttribute("content") : null) ?? el.content;
        if (typeof val === "string" && val.trim()) {
          return val.trim();
        }
      }
    }

    if (typeof doc.getElementsByTagName === "function") {
      const metas = doc.getElementsByTagName("meta");
      for (let i = 0; i < metas.length; i += 1) {
        const item = metas[i] ;
        const itemName = (typeof item.getAttribute === "function" ? item.getAttribute("name") : null) ?? item.name;
        if (itemName === metaName) {
          const val = (typeof item.getAttribute === "function" ? item.getAttribute("content") : null) ?? item.content;
          if (typeof val === "string" && val.trim()) {
            return val.trim();
          }
        }
      }
    }

    return undefined;
  }

  /**
   * Reads Rails `<meta name="sentrace-*">` tags emitted by `sentrace_meta_tags`.
   */
  function readRailsMeta(customDoc          )                  {
    const doc = (customDoc ?? (globalThis                          ).document)                                 ;
    if (!doc) {
      return {};
    }

    return {
      dsn: readMetaTagContent(doc, "sentrace-dsn"),
      environment: readMetaTagContent(doc, "sentrace-environment"),
      release: readMetaTagContent(doc, "sentrace-release"),
      requestId: readMetaTagContent(doc, "sentrace-request-id")
    };
  }

  /**
   * Attaches Hotwire Turbo lifecycle and error listeners (`turbo:visit`, `turbo:load`,
   * `turbo:fetch-request-error`, `turbo:frame-missing`).
   */
  function installRailsTurboInstrumentation(
    hooks                       ,
    customDoc
  )             {
    const doc = (customDoc ?? (globalThis                          ).document)                                 ;
    if (!doc || typeof doc.addEventListener !== "function" || typeof doc.removeEventListener !== "function") {
      return () => {};
    }

    const onTurboVisit = (rawEvent         )       => {
      const detail = (rawEvent                                                  )?.detail;
      hooks.onBreadcrumb({
        type: "navigation",
        category: "turbo.visit",
        level: "info",
        data: {
          url: scrubUrl(detail?.url, hooks.redactFields),
          ...(detail?.action ? { action: detail.action } : {})
        }
      });
    };

    const onTurboLoad = ()       => {
      const refreshed = readRailsMeta(doc);
      if (refreshed.requestId) {
        hooks.onRequestIdChange(refreshed.requestId);
      }
    };

    const onTurboFetchRequestError = (rawEvent         )       => {
      const ev = rawEvent

       ;
      const rawUrl = ev?.detail?.url ? String(ev.detail.url) : ev?.detail?.request?.url;
      const safeUrl = scrubUrl(rawUrl, hooks.redactFields);
      const requestId = ev?.detail?.response?.headers?.get?.("x-request-id") ?? undefined;
      if (requestId) {
        hooks.onRequestIdChange(requestId);
      }

      const underlying =
        ev?.detail?.error instanceof Error
          ? ev.detail.error
          : new Error(`Turbo fetch request failed${safeUrl ? ` for ${safeUrl}` : ""}`);
      if (!(ev?.detail?.error instanceof Error)) {
        underlying.name = "TurboFetchRequestError";
      }

      hooks.captureException(underlying, {
        tags: {
          "rails.turbo": "fetch-request-error",
          ...(requestId ? { request_id: requestId } : {})
        },
        contexts: {
          turbo: {
            event: "turbo:fetch-request-error",
            ...(safeUrl ? { url: safeUrl } : {})
          }
        }
      });
    };

    const onTurboFrameMissing = (rawEvent         )       => {
      const ev = rawEvent

       ;

      const frameId = ev?.target?.id || "unknown";
      const status = ev?.detail?.response?.status;
      const safeUrl = scrubUrl(ev?.detail?.response?.url, hooks.redactFields);
      const requestId = ev?.detail?.response?.headers?.get?.("x-request-id") ?? undefined;
      if (requestId) {
        hooks.onRequestIdChange(requestId);
      }

      const err = new Error(
        `Turbo frame #${frameId} missing in response${status !== undefined ? ` (HTTP ${status})` : ""}`
      );
      err.name = "TurboFrameMissingError";

      hooks.captureException(err, {
        tags: {
          "rails.turbo": "frame-missing",
          "turbo.frame": frameId,
          ...(requestId ? { request_id: requestId } : {})
        },
        contexts: {
          turbo: {
            event: "turbo:frame-missing",
            frame_id: frameId,
            ...(status !== undefined ? { status_code: status } : {}),
            ...(safeUrl ? { url: safeUrl } : {})
          }
        }
      });
    };

    doc.addEventListener("turbo:visit", onTurboVisit);
    doc.addEventListener("turbo:load", onTurboLoad);
    doc.addEventListener("turbo:fetch-request-error", onTurboFetchRequestError);
    doc.addEventListener("turbo:frame-missing", onTurboFrameMissing);

    return () => {
      doc.removeEventListener?.("turbo:visit", onTurboVisit);
      doc.removeEventListener?.("turbo:load", onTurboLoad);
      doc.removeEventListener?.("turbo:fetch-request-error", onTurboFetchRequestError);
      doc.removeEventListener?.("turbo:frame-missing", onTurboFrameMissing);
    };
  }

  /**
   * Wraps a Hotwire Stimulus `Application.handleError` callback so controller errors
   * are captured with controller identifier and action metadata while preserving Stimulus's default handler.
   */
  function bindStimulusErrorHandler(
    application                         ,
    captureFn
  )             {
    if (!application || typeof application !== "object") {
      return () => {};
    }

    const originalHandler =
      typeof application.handleError === "function" ? application.handleError.bind(application) : null;

    const wrappedHandler = (error       , message        , detail                          = {})       => {
      const identifier =
        (typeof detail.identifier === "string" && detail.identifier) ||
        (typeof (detail.controller                                       )?.identifier === "string"
          ? (detail.controller                          ).identifier
          : undefined);
      const action = typeof detail.action === "string" ? detail.action : undefined;

      captureFn(error, {
        tags: {
          "rails.stimulus": "true",
          ...(identifier ? { "stimulus.controller": identifier } : {}),
          ...(action ? { "stimulus.action": action } : {})
        },
        contexts: {
          stimulus: {
            message,
            ...(identifier ? { controller: identifier } : {}),
            ...(action ? { action } : {})
          }
        }
      });

      if (originalHandler) {
        originalHandler(error, message, detail);
      }
    };

    application.handleError = wrappedHandler;

    return () => {
      if (application.handleError === wrappedHandler && originalHandler) {
        application.handleError = originalHandler;
      }
    };
  }

  // --- client.ts ---
  function matchesPattern(value        , pattern                 )          {
    if (typeof pattern === "string") {
      return value.includes(pattern);
    }
    return pattern.test(value);
  }

  class BrowserClient {
             config                    ;
                     options                 ;
                     parsedDsn                  ;
                     endpointUrl               ;
                     transport                  ;
                     redactFields          ;
            closed = false;
                     teardowns                    = [];

    constructor(options                 , scope       ) {
      const useRails = options.railsIntegration !== false;
      const railsMeta = useRails ? readRailsMeta() : {};

      const resolvedDsn = options.dsn !== undefined ? options.dsn : (railsMeta.dsn ?? null);
      const resolvedEnv = options.environment ?? railsMeta.environment ?? "production";
      const resolvedRelease =
        options.release !== undefined ? options.release : (railsMeta.release ?? null);

      this.options = options;
      this.redactFields = options.redactFields ? [...options.redactFields] : [];
      this.config = Object.freeze({
        enabled: options.enabled ?? true,
        dsn: resolvedDsn ?? null,
        environment: resolvedEnv,
        release: resolvedRelease ?? null,
        sampleRate: options.sampleRate ?? 1.0,
        maxBreadcrumbs: options.maxBreadcrumbs ?? 20,
        maxStackFrames: options.maxStackFrames ?? 50
      });

      if (railsMeta.requestId) {
        scope.setTag("request_id", railsMeta.requestId);
      }

      this.parsedDsn = parseDsn(this.config.dsn);
      this.endpointUrl = this.parsedDsn ? buildEnvelopeEndpoint(this.parsedDsn) : null;
      this.transport =
        this.parsedDsn && this.endpointUrl
          ? options.transport
            ? options.transport(this.parsedDsn, this.endpointUrl)
            : createBrowserTransport(this.endpointUrl)
          : null;

      if (options.autoInstrumentBrowser !== false) {
        this.teardowns.push(
          installBrowserInstrumentation({
            endpointUrl: this.endpointUrl,
            redactFields: this.redactFields,
            onError: (err, meta) => {
              this.captureExceptionWithMeta(err, scope, undefined, meta);
            },
            onBreadcrumb: (crumb) => {
              this.recordBreadcrumb(crumb, scope);
            },
            onCorrelatedRequestId: (reqId) => {
              scope.setTag("request_id", reqId);
            }
          })
        );
      }

      if (useRails) {
        this.teardowns.push(
          installRailsTurboInstrumentation({
            redactFields: this.redactFields,
            onBreadcrumb: (crumb) => {
              this.recordBreadcrumb(crumb, scope);
            },
            onRequestIdChange: (reqId) => {
              scope.setTag("request_id", reqId);
            },
            captureException: (err, context) => this.captureException(err, scope, context)
          })
        );
      }
    }

    recordBreadcrumb(breadcrumb            , scope       )       {
      if (this.closed || !this.config.enabled) {
        return;
      }

      let candidate                    = { ...breadcrumb };
      if (this.options.beforeBreadcrumb) {
        candidate = this.options.beforeBreadcrumb(candidate);
        if (!candidate) {
          return;
        }
      }
      scope.addBreadcrumb(candidate, this.config.maxBreadcrumbs);
    }

    captureException(error         , scope       , captureContext                 )         {
      return this.captureExceptionWithMeta(error, scope, captureContext, {
        handled: true,
        mechanismType: "generic"
      });
    }

    captureExceptionWithMeta(
      error         ,
      scope       ,
      captureContext                            ,
      meta
    )         {
      const syntheticException = error instanceof Error ? undefined : new Error("Synthetic stacktrace");
      const values = extractExceptionChain(
        error,
        this.config.maxStackFrames,
        meta.handled,
        meta.mechanismType,
        syntheticException
      );

      if (meta.fallbackFrame && values.length > 0) {
        const top = values[values.length - 1] ;
        if (!top.stacktrace || top.stacktrace.frames.length === 0) {
          top.stacktrace = { frames: [meta.fallbackFrame] };
        }
      }

      const eventId = generateEventId();
      const baseEvent              = {
        event_id: eventId,
        timestamp: new Date().toISOString(),
        platform: "javascript",
        level: "error",
        environment: this.config.environment,
        ...(this.config.release ? { release: this.config.release } : {}),
        exception: { values },
        sdk: { name: SDK_NAME, version: VERSION }
      };

      const effectiveScope = captureContext ? scope.clone().applyCaptureContext(captureContext) : scope;
      return this.prepareAndSend(baseEvent, effectiveScope, {
        event_id: eventId,
        originalException: error,
        syntheticException
      });
    }

    captureMessage(
      message        ,
      scope       ,
      levelOrContext                                 ,
      maybeContext
    )         {
      const eventId = generateEventId();
      let explicitLevel                           ;
      let captureContext                             = maybeContext;

      if (typeof levelOrContext === "string") {
        explicitLevel = levelOrContext;
      } else if (levelOrContext !== undefined) {
        captureContext = levelOrContext;
      }

      const baseEvent              = {
        event_id: eventId,
        timestamp: new Date().toISOString(),
        platform: "javascript",
        ...(explicitLevel ? { level: explicitLevel } : {}),
        environment: this.config.environment,
        ...(this.config.release ? { release: this.config.release } : {}),
        message: String(message),
        sdk: { name: SDK_NAME, version: VERSION }
      };

      const effectiveScope = captureContext ? scope.clone().applyCaptureContext(captureContext) : scope;
      if (!baseEvent.level) {
        baseEvent.level = "info";
      }
      return this.prepareAndSend(baseEvent, effectiveScope, {
        event_id: eventId,
        originalException: message
      });
    }

    captureEvent(partialEvent                      , scope       , hint                  )         {
      const eventId =
        partialEvent.event_id && /^[0-9a-f]{32}$/i.test(partialEvent.event_id.replace(/-/g, ""))
          ? partialEvent.event_id.replace(/-/g, "").toLowerCase()
          : generateEventId();

      const baseEvent              = {
        ...partialEvent,
        event_id: eventId,
        timestamp: partialEvent.timestamp ?? new Date().toISOString(),
        platform: "javascript",
        environment: partialEvent.environment ?? this.config.environment,
        ...(partialEvent.release ?? this.config.release
          ? { release: (partialEvent.release ?? this.config.release) || undefined }
          : {}),
        sdk: partialEvent.sdk ?? { name: SDK_NAME, version: VERSION }
      };

      return this.prepareAndSend(baseEvent, scope, {
        ...hint,
        event_id: eventId
      });
    }

    async flush(timeout = 2000)                   {
      if (!this.transport) {
        return true;
      }
      return this.transport.flush(timeout);
    }

    async close(timeout = 2000)                   {
      this.closed = true;
      this.teardownInstrumentation();
      return this.flush(timeout);
    }

    teardownInstrumentation()       {
      for (const fn of this.teardowns.splice(0)) {
        fn();
      }
    }

            prepareAndSend(event             , scope       , hint                 )         {
      const eventId = event.event_id;
      if (this.closed || !this.config.enabled || !this.parsedDsn || !this.transport) {
        return eventId;
      }

      if (this.config.sampleRate <= 0 || (this.config.sampleRate < 1 && Math.random() >= this.config.sampleRate)) {
        return eventId;
      }

      if (!event.request) {
        const currentHref = (globalThis                                                                               )
          .window?.location?.href ?? (globalThis                                    ).location?.href;
        const safeHref = scrubUrl(currentHref, this.redactFields);
        if (safeHref) {
          event.request = { url: safeHref };
        }
      } else if (event.request.url) {
        event.request = {
          ...event.request,
          url: scrubUrl(event.request.url, this.redactFields)
        };
      }

      scope.applyToEvent(event, this.config.maxBreadcrumbs);

      if (this.shouldFilterEvent(event)) {
        return eventId;
      }

      let finalEvent                     = event;
      if (this.options.beforeSend) {
        finalEvent = this.options.beforeSend(event, hint);
        if (!finalEvent) {
          return eventId;
        }
      }

      const envelope = serializeEnvelope(finalEvent, this.parsedDsn);
      void this.transport.send(envelope);
      return finalEvent.event_id || eventId;
    }

            shouldFilterEvent(event             )          {
      const ignoreErrors = this.options.ignoreErrors;
      if (ignoreErrors && ignoreErrors.length > 0) {
        const candidates           = [];
        if (event.message) {
          candidates.push(event.message);
        }
        for (const exc of event.exception?.values ?? []) {
          if (exc.value) {
            candidates.push(exc.value);
            candidates.push(`${exc.type}: ${exc.value}`);
          }
        }
        if (candidates.some((text) => ignoreErrors.some((pat) => matchesPattern(text, pat)))) {
          return true;
        }
      }

      const frames = event.exception?.values?.flatMap((v) => v.stacktrace?.frames ?? []) ?? [];
      const filenames = frames.map((f) => f.filename || f.abs_path || "").filter(Boolean);

      if (this.options.denyUrls && this.options.denyUrls.length > 0 && filenames.length > 0) {
        const denied = filenames.some((url) => this.options.denyUrls .some((pat) => matchesPattern(url, pat)));
        if (denied) {
          return true;
        }
      }

      if (this.options.allowUrls && this.options.allowUrls.length > 0 && filenames.length > 0) {
        const allowed = filenames.some((url) => this.options.allowUrls .some((pat) => matchesPattern(url, pat)));
        if (!allowed) {
          return true;
        }
      }

      return false;
    }
  }

  // Singleton hub state
  let activeClient                       = null;
  let globalScope = new Scope();
  const scopeStack          = [];

  function activeScope()        {
    return scopeStack.length > 0 ? scopeStack[scopeStack.length - 1]  : globalScope;
  }

  function init(options                  = {})                     {
    if (activeClient) {
      activeClient.teardownInstrumentation();
    }
    globalScope = new Scope();
    scopeStack.length = 0;
    activeClient = new BrowserClient(options, globalScope);
    return activeClient.config;
  }

  function initRails(options                  = {})                     {
    return init({ ...options, railsIntegration: true });
  }

  function getConfig()                            {
    return activeClient ? activeClient.config : null;
  }

  function getClient()                            {
    return activeClient ?? undefined;
  }

  function isInitialized()          {
    return activeClient !== null;
  }

  function getCurrentScope()        {
    return activeScope();
  }

  function getGlobalScope()        {
    return globalScope;
  }

  function getIsolationScope()        {
    return activeScope();
  }

  function withScope   (callback                     )    {
    const forked = activeScope().clone();
    scopeStack.push(forked);
    try {
      return callback(forked);
    } finally {
      scopeStack.pop();
    }
  }

  function captureException(error         , captureContext                 )         {
    if (!activeClient) {
      return generateEventId();
    }
    return activeClient.captureException(error, activeScope(), captureContext);
  }

  function captureMessage(
    message        ,
    levelOrContext                                 ,
    maybeContext
  )         {
    if (!activeClient) {
      return generateEventId();
    }
    return activeClient.captureMessage(message, activeScope(), levelOrContext, maybeContext);
  }

  function captureEvent(event                      , hint                  )         {
    if (!activeClient) {
      return event.event_id ?? generateEventId();
    }
    return activeClient.captureEvent(event, activeScope(), hint);
  }

  function addBreadcrumb(breadcrumb            )       {
    if (activeClient) {
      activeClient.recordBreadcrumb(breadcrumb, activeScope());
    } else {
      activeScope().addBreadcrumb(breadcrumb);
    }
  }

  function clearBreadcrumbs()       {
    activeScope().clearBreadcrumbs();
  }

  function setTag(key        , value                           )       {
    activeScope().setTag(key, value);
  }

  function setTags(tags                                           )       {
    activeScope().setTags(tags);
  }

  function setUser(user             )       {
    activeScope().setUser(user);
  }

  function setContext(name        , context                                )       {
    activeScope().setContext(name, context);
  }

  function setExtra(key        , extra         )       {
    activeScope().setExtra(key, extra);
  }

  function setExtras(extras                         )       {
    activeScope().setExtras(extras);
  }

  async function flush(timeout = 2000)                   {
    if (!activeClient) {
      return true;
    }
    return activeClient.flush(timeout);
  }

  async function close(timeout = 2000)                   {
    if (!activeClient) {
      return true;
    }
    const client = activeClient;
    activeClient = null;
    return client.close(timeout);
  }

  function resetClient()       {
    if (activeClient) {
      activeClient.teardownInstrumentation();
    }
    activeClient = null;
    globalScope = new Scope();
    scopeStack.length = 0;
  }

  function registerStimulusErrorHandler(application                         )             {
    return bindStimulusErrorHandler(application, captureException);
  }

  const Sentrace = {
    VERSION,
    SDK_NAME,
    SDK_CLIENT,
    BrowserClient,
    Scope,
    init,
    initRails,
    getConfig,
    getClient,
    isInitialized,
    getCurrentScope,
    getGlobalScope,
    getIsolationScope,
    withScope,
    captureException,
    captureMessage,
    captureEvent,
    addBreadcrumb,
    clearBreadcrumbs,
    setTag,
    setTags,
    setUser,
    setContext,
    setExtra,
    setExtras,
    flush,
    close,
    resetClient,
    readRailsMeta,
    registerStimulusErrorHandler,
    parseDsn,
    formatPublicDsn,
    buildEnvelopeEndpoint,
    scrubUrl,
    generateEventId,
    serializeEnvelope,
    createBrowserTransport,
    isInAppFilename,
    parseStackLine,
    parseStackFrames,
    extractExceptionChain
  };

  root.Sentrace = Sentrace;
})(typeof globalThis !== "undefined" ? globalThis : typeof window !== "undefined" ? window : this);
