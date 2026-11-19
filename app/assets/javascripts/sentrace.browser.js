(function (root) {
  "use strict";
  // --- dsn.ts ---
  const VERSION = "0.1.2";
  const SDK_NAME = "sentrace.javascript.browser";
  const SDK_CLIENT = `sentrace-js/${VERSION}`;

  function getGlobalObject()                          {
    if (typeof globalThis !== "undefined") {
      return globalThis                                      ;
    }
    if (typeof window !== "undefined") {
      return window                                      ;
    }
    if (typeof self !== "undefined") {
      return self                                      ;
    }
    return {};
  }

  function nullishCoalesce   (value                      , fallback   )    {
    return value !== undefined && value !== null ? value : fallback;
  }

  const DEFAULT_SENSITIVE_QUERY_KEYS = [
    "password",
    "passwd",
    "passcode",
    "secret",
    "secret_key",
    "secret-key",
    "secretkey",
    "token",
    "access_token",
    "refresh_token",
    "id_token",
    "api_key",
    "api-key",
    "apikey",
    "private_key",
    "private-key",
    "privatekey",
    "access_key",
    "access-key",
    "accesskey",
    "authorization",
    "cookie",
    "credit_card",
    "credit-card",
    "card_number",
    "card-number",
    "cvv",
    "cvc",
    "sentry_secret"
  ];

  const SENSITIVE_BOUNDED_QUERY_KEY_REGEX = /(?:^|[_.-])(?:ssn|otp|totp)(?:$|[_.-])/;

  const AUTH_SESSION_EXACT_KEYS = [
    "session",
    "session_id",
    "_session_id",
    "rack.session",
    "phpsessid",
    "jsessionid",
    "connect.sid"
  ];

  const AUTH_SESSION_KEY_REGEX = /^_(?:[a-z0-9_]+_)?session$|(?:^|[_.-])session[_.-]?token$/;
  const SAFE_REQUEST_ID_REGEX = /^[A-Za-z0-9._:-]{1,128}$/;

  function normalizeSafeRequestId(rawValue         )                     {
    if (typeof rawValue !== "string") {
      return undefined;
    }
    const trimmed = rawValue.trim();
    return SAFE_REQUEST_ID_REGEX.test(trimmed) ? trimmed : undefined;
  }

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
    } catch (_err) {
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
    if (!/^[1-9]\d*$/.test(projectId)) {
      return null;
    }

    let decodedPublicKey        ;
    try {
      decodedPublicKey = decodeURIComponent(uri.username);
    } catch (_err) {
      return null;
    }
    if (!decodedPublicKey || /[\s\x00-\x1f\x7f]/.test(decodedPublicKey)) {
      return null;
    }

    const pathPrefix = segments.length > 0 ? `/${segments.join("/")}` : "";

    return {
      protocol,
      publicKey: decodedPublicKey,
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

  function scrubUrl(
    rawUrl                    ,
    extraRedactFields           = [],
    allowFields           = []
  )                     {
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
    const allowSet = new Set(
      allowFields.map((f) => String(f).trim().toLowerCase()).filter(Boolean)
    );

    const isSensitive = (key        )          => {
      const lower = key.trim().toLowerCase();
      if (allowSet.has(lower)) {
        return false;
      }
      if (AUTH_SESSION_EXACT_KEYS.indexOf(lower) !== -1 || AUTH_SESSION_KEY_REGEX.test(lower)) {
        return true;
      }
      if (SENSITIVE_BOUNDED_QUERY_KEY_REGEX.test(lower)) {
        return true;
      }
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
    } catch (_err) {
      const withoutQuery = trimmed.split("?")[0];
      return withoutQuery ? withoutQuery.replace(/\/\/[^/@]+@/, "//") : trimmed;
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
      const ctorName = err.constructor && typeof err.constructor.name === "string" ? err.constructor.name : "";
      return {
        type: err.name || ctorName || "Error",
        value: err.message || String(err),
        ...(frames.length > 0 ? { stacktrace: { frames } } : {}),
        mechanism: { type: mechanismType, handled }
      };
    }

    if (typeof err === "object" && err !== null) {
      const obj = err                           ;
      const ctor = obj.constructor                                  ;
      const ctorName = ctor && typeof ctor.name === "string" && ctor.name !== "Object" ? ctor.name : "";
      const typeName = (typeof obj.name === "string" && obj.name) || ctorName || "Error";
      const message =
        typeof obj.message === "string"
          ? obj.message
          : (() => {
              try {
                return JSON.stringify(obj);
              } catch (_err) {
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
      if (depth === 0 && !entry.stacktrace && syntheticException && syntheticException.stack) {
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
  function isUnsafeScopeKey(key        )          {
    return key === "__proto__" || key === "constructor" || key === "prototype";
  }

  class Scope                      {

    constructor() {
      this.tags = {};
      this.user = null;
      this.contexts = {};
      this.extra = {};
      this.breadcrumbs = [];
      this.fingerprint = undefined;
      this.level = undefined;
    }

    setTag(key        , value                           )       {
      const normalizedKey = String(key);
      if (!isUnsafeScopeKey(normalizedKey)) {
        this.tags[normalizedKey] = String(value);
      }
      return this;
    }

    setTags(tags                                           )       {
      for (const [k, v] of Object.entries(tags)) {
        if (!isUnsafeScopeKey(k) && v !== undefined && v !== null) {
          this.tags[k] = String(v);
        }
      }
      return this;
    }

    getTag(key        )                     {
      if (isUnsafeScopeKey(key) || !Object.prototype.hasOwnProperty.call(this.tags, key)) {
        return undefined;
      }
      return this.tags[key];
    }

    setUser(user             )       {
      this.user = user ? { ...user } : null;
      return this;
    }

    setContext(name        , context                                )       {
      if (isUnsafeScopeKey(name)) {
        return this;
      }
      if (context === null) {
        delete this.contexts[name];
      } else {
        const cleaned                          = {};
        for (const [k, v] of Object.entries(context)) {
          if (!isUnsafeScopeKey(k)) {
            cleaned[k] = v;
          }
        }
        this.contexts[name] = cleaned;
      }
      return this;
    }

    setExtra(key        , extra         )       {
      if (!isUnsafeScopeKey(key)) {
        this.extra[key] = extra;
      }
      return this;
    }

    setExtras(extras                         )       {
      for (const [k, v] of Object.entries(extras)) {
        if (!isUnsafeScopeKey(k)) {
          this.extra[k] = v;
        }
      }
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
        timestamp:
          breadcrumb.timestamp !== undefined && breadcrumb.timestamp !== null
            ? breadcrumb.timestamp
            : new Date().toISOString()
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

    trimBreadcrumbs(maxBreadcrumbs        )       {
      if (maxBreadcrumbs <= 0) {
        this.breadcrumbs = [];
        return this;
      }
      if (this.breadcrumbs.length > maxBreadcrumbs) {
        this.breadcrumbs.splice(0, this.breadcrumbs.length - maxBreadcrumbs);
      }
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
      const mergedTags = { ...this.tags, ...(event.tags ? event.tags : {}) };
      if (Object.keys(mergedTags).length > 0) {
        event.tags = mergedTags;
      }

      const mergedExtra = { ...this.extra, ...(event.extra ? event.extra : {}) };
      if (Object.keys(mergedExtra).length > 0) {
        event.extra = mergedExtra;
      }

      const mergedContexts                                          = {};
      for (const [k, v] of Object.entries(this.contexts)) {
        if (!isUnsafeScopeKey(k)) {
          mergedContexts[k] = { ...v };
        }
      }
      if (event.contexts) {
        for (const [k, v] of Object.entries(event.contexts)) {
          if (!isUnsafeScopeKey(k) && v && typeof v === "object") {
            const existing = Object.prototype.hasOwnProperty.call(mergedContexts, k) ? mergedContexts[k] : undefined;
            mergedContexts[k] = { ...(existing ? existing : {}), ...v };
          }
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

      const existingCrumbs = event.breadcrumbs && event.breadcrumbs.values ? event.breadcrumbs.values : [];
      const combinedCrumbs = [...this.breadcrumbs, ...existingCrumbs].slice(-Math.max(0, maxBreadcrumbs));
      if (combinedCrumbs.length > 0) {
        event.breadcrumbs = { values: combinedCrumbs };
      }

      return event;
    }
  }

  // --- envelope.ts ---
  function generateEventId()         {
    const g = getGlobalObject()

     ;

    if (g.crypto && typeof g.crypto.randomUUID === "function") {
      return g.crypto.randomUUID().replace(/-/g, "").toLowerCase();
    }

    if (g.crypto && typeof g.crypto.getRandomValues === "function") {
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
        const nav = (
          getGlobalObject()
        ).navigator;
        if (nav && typeof nav.sendBeacon === "function") {
          return nav.sendBeacon(endpointUrl, envelope);
        }
      } catch (_err) {
        // Ignore sendBeacon errors
      }
      return false;
    };

    const send = (envelope        )                                        => {
      const g = getGlobalObject();
      const doc = (g                                               ).document;
      if (doc && doc.visibilityState === "hidden" && sendViaBeacon(envelope)) {
        return Promise.resolve({ statusCode: 200 });
      }

      const fetchFn = (g                            ).fetch;
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
        .catch((_err) => {
          const fallbackOk = sendViaBeacon(envelope);
          return { statusCode: fallbackOk ? 200 : 0 };
        });

      pending.add(requestPromise);
      void requestPromise.then(
        () => {
          pending.delete(requestPromise);
        },
        () => {
          pending.delete(requestPromise);
        }
      );

      return requestPromise;
    };

    const flush = async (timeout = 2000)                   => {
      if (pending.size === 0) {
        return true;
      }

      const settled = Array.from(pending).map((p) =>
        p.then(
          () => undefined,
          () => undefined
        )
      );
      const allDone = Promise.all(settled).then(() => true);
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
    let active = true;
    const cleanups                    = [];
    const g = getGlobalObject();
    const win = (g.window !== undefined && g.window !== null ? g.window : g)

     ;
    const doc = g.document

                 ;

    if (win && typeof win.addEventListener === "function" && typeof win.removeEventListener === "function") {
      const errorListener = (rawEvent         )       => {
        if (!active) {
          return;
        }
        const ev = rawEvent

                     ;
        const err =
          ev && ev.error !== undefined && ev.error !== null
            ? ev.error
            : new Error((ev && ev.message) || "Uncaught window error");
        const fallbackFrame                         =
          ev && ev.filename
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
        if (!active) {
          return;
        }
        const ev = rawEvent                                    ;
        const reason = ev && "reason" in ev ? ev.reason : new Error("Unhandled Promise rejection");
        hooks.onError(reason !== undefined && reason !== null ? reason : new Error("Unhandled Promise rejection"), {
          handled: false,
          mechanismType: "onunhandledrejection"
        });
      };

      win.addEventListener("error", errorListener);
      win.addEventListener("unhandledrejection", rejectionListener);
      cleanups.push(() => {
        if (typeof win.removeEventListener === "function") {
          win.removeEventListener("error", errorListener);
          win.removeEventListener("unhandledrejection", rejectionListener);
        }
      });

      let lastHref = win.location ? win.location.href : undefined;
      const popstateListener = ()       => {
        if (!active) {
          return;
        }
        const nextHref = win.location ? win.location.href : undefined;
        hooks.onBreadcrumb({
          type: "navigation",
          category: "navigation",
          level: "info",
          data: {
            from: scrubUrl(lastHref, hooks.redactFields, hooks.allowFields),
            to: scrubUrl(nextHref, hooks.redactFields, hooks.allowFields)
          }
        });
        lastHref = nextHref;
      };
      win.addEventListener("popstate", popstateListener);
      cleanups.push(() => {
        if (typeof win.removeEventListener === "function") {
          win.removeEventListener("popstate", popstateListener);
        }
      });

      if (win.history) {
        const historyObj = win.history;
        for (const methodName of ["pushState", "replaceState"]         ) {
          const original = historyObj[methodName];
          if (typeof original === "function") {
            const wrappedHistory = function patchedHistory(...args           )          {
              if (!active) {
                return original.apply(this, args);
              }
              const currentLocHref = win.location ? win.location.href : undefined;
              const prev = lastHref !== undefined && lastHref !== null ? lastHref : currentLocHref;
              const result = original.apply(this, args);
              let nextUrl = win.location ? win.location.href : undefined;
              if ((!nextUrl || nextUrl === prev) && args[2] !== undefined && args[2] !== null) {
                try {
                  nextUrl = prev ? new URL(String(args[2]), prev).toString() : String(args[2]);
                } catch (_err) {
                  nextUrl = String(args[2]);
                }
              }
              lastHref = nextUrl;
              hooks.onBreadcrumb({
                type: "navigation",
                category: "navigation",
                level: "info",
                data: {
                  from: scrubUrl(prev, hooks.redactFields, hooks.allowFields),
                  to: scrubUrl(nextUrl, hooks.redactFields, hooks.allowFields)
                }
              });
              return result;
            };
            historyObj[methodName] = wrappedHistory;
            cleanups.push(() => {
              if (historyObj[methodName] === wrappedHistory) {
                historyObj[methodName] = original;
              }
            });
          }
        }
      }
    }

    if (doc && typeof doc.addEventListener === "function" && typeof doc.removeEventListener === "function") {
      const clickListener = (rawEvent         )       => {
        if (!active) {
          return;
        }
        const ev = rawEvent                                    ;
        hooks.onBreadcrumb({
          type: "ui",
          category: "ui.click",
          level: "info",
          message: describeElement(ev ? ev.target : undefined)
        });
      };
      doc.addEventListener("click", clickListener, true);
      cleanups.push(() => {
        if (typeof doc.removeEventListener === "function") {
          doc.removeEventListener("click", clickListener, true);
        }
      });
    }

    if (typeof g.fetch === "function") {
      const originalFetch = g.fetch                ;
      const wrappedFetch = function sentraceFetch(
        input                   ,
        init
      )                    {
        if (!active || (init && init[SENTRACE_INTERNAL_FETCH_FLAG])) {
          return originalFetch.call(g, input, init);
        }

        const inputObj = typeof input === "object" && input !== null ? (input                                       ) : null;
        const rawUrl =
          typeof input === "string"
            ? input
            : input instanceof URL
              ? input.toString()
              : inputObj && typeof inputObj.url === "string"
                ? inputObj.url
                : "";

        if (isInternalEndpoint(rawUrl, hooks.endpointUrl)) {
          return originalFetch.call(g, input, init);
        }

        const rawMethod =
          init && init.method !== undefined && init.method !== null
            ? init.method
            : inputObj && typeof inputObj.method === "string"
              ? inputObj.method
              : "GET";
        const method = String(rawMethod).toUpperCase();
        const safeUrl = scrubUrl(rawUrl, hooks.redactFields, hooks.allowFields);

        return originalFetch.call(g, input, init).then(
          (response) => {
            if (!active) {
              return response;
            }
            let requestId                    ;
            if (response && response.headers && typeof response.headers.get === "function") {
              requestId = normalizeSafeRequestId(response.headers.get("x-request-id"));
            }
            const status = response && typeof response.status === "number" ? response.status : undefined;

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
            if (active) {
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
            }
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

    if (
      XhrCtor &&
      XhrCtor.prototype &&
      typeof XhrCtor.prototype.open === "function" &&
      typeof XhrCtor.prototype.send === "function"
    ) {
      const proto = XhrCtor.prototype;
      const origOpen = proto.open ;
      const origSend = proto.send ;

      const wrappedOpen = function sentraceXhrOpen(

        method        ,
        url              ,
        ...rest
      )          {
        if (active) {
          this.__sentraceXhrMeta = {
            method: String(method || "GET").toUpperCase(),
            url: String(url || "")
          };
        }
        return origOpen.call(this, method, url, ...rest);
      };

      const wrappedSend = function sentraceXhrSend(                               body          )          {
        if (!active) {
          return origSend.call(this, body);
        }
        const meta = this.__sentraceXhrMeta                                               ;
        if (meta && !isInternalEndpoint(meta.url, hooks.endpointUrl)) {
          const onLoadEnd = ()       => {
            if (!active) {
              return;
            }
            const status = typeof this.status === "number" ? this.status : undefined;
            const getHeader = this.getResponseHeader                                                 ;
            let requestId                    ;
            if (typeof getHeader === "function") {
              try {
                requestId = normalizeSafeRequestId(getHeader.call(this, "x-request-id"));
              } catch (_err) {
                requestId = undefined;
              }
            }

            if (requestId && status !== undefined && status >= 400) {
              hooks.onCorrelatedRequestId(requestId);
            }

            hooks.onBreadcrumb({
              type: "http",
              category: "xhr",
              level: status !== undefined && status >= 400 ? "warning" : "info",
              data: {
                method: meta.method,
                url: scrubUrl(meta.url, hooks.redactFields, hooks.allowFields),
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

      proto.open = wrappedOpen;
      proto.send = wrappedSend;

      cleanups.push(() => {
        if (proto.open === wrappedOpen) {
          proto.open = origOpen;
        }
        if (proto.send === wrappedSend) {
          proto.send = origSend;
        }
      });
    }

    return () => {
      active = false;
      for (const fn of cleanups.splice(0)) {
        try {
          fn();
        } catch (_err) {
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
        const attrVal = typeof el.getAttribute === "function" ? el.getAttribute("content") : null;
        const val = attrVal !== null && attrVal !== undefined ? attrVal : el.content;
        if (typeof val === "string" && val.trim()) {
          return val.trim();
        }
      }
    }

    if (typeof doc.getElementsByTagName === "function") {
      const metas = doc.getElementsByTagName("meta");
      for (let i = 0; i < metas.length; i += 1) {
        const item = metas[i] ;
        const attrName = typeof item.getAttribute === "function" ? item.getAttribute("name") : null;
        const itemName = attrName !== null && attrName !== undefined ? attrName : item.name;
        if (itemName === metaName) {
          const attrVal = typeof item.getAttribute === "function" ? item.getAttribute("content") : null;
          const val = attrVal !== null && attrVal !== undefined ? attrVal : item.content;
          if (typeof val === "string" && val.trim()) {
            return val.trim();
          }
        }
      }
    }

    return undefined;
  }

  function readHeaderSafely(headers                                                    , name        )                     {
    if (!headers || typeof headers.get !== "function") {
      return undefined;
    }
    try {
      const raw = headers.get(name);
      return raw !== null && raw !== undefined ? raw : undefined;
    } catch (_err) {
      return undefined;
    }
  }

  /**
   * Reads Rails `<meta name="sentrace-*">` tags emitted by `sentrace_meta_tags`.
   */
  function readRailsMeta(customDoc          )                  {
    const rawDoc = customDoc !== undefined && customDoc !== null ? customDoc : getGlobalObject().document;
    const doc = rawDoc                                 ;
    if (!doc) {
      return {};
    }

    return {
      dsn: readMetaTagContent(doc, "sentrace-dsn"),
      environment: readMetaTagContent(doc, "sentrace-environment"),
      release: readMetaTagContent(doc, "sentrace-release"),
      requestId: normalizeSafeRequestId(readMetaTagContent(doc, "sentrace-request-id"))
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
    let active = true;
    const rawDoc = customDoc !== undefined && customDoc !== null ? customDoc : getGlobalObject().document;
    const doc = rawDoc                                 ;
    if (!doc || typeof doc.addEventListener !== "function" || typeof doc.removeEventListener !== "function") {
      return () => {};
    }

    const onTurboVisit = (rawEvent         )       => {
      if (!active) {
        return;
      }
      const ev = rawEvent                                                              ;
      const detail = ev ? ev.detail : undefined;
      hooks.onBreadcrumb({
        type: "navigation",
        category: "turbo.visit",
        level: "info",
        data: {
          url: scrubUrl(detail ? detail.url : undefined, hooks.redactFields, hooks.allowFields),
          ...(detail && detail.action ? { action: detail.action } : {})
        }
      });
    };

    const onTurboLoad = ()       => {
      if (!active) {
        return;
      }
      const refreshed = readRailsMeta(doc);
      if (refreshed.requestId) {
        hooks.onRequestIdChange(refreshed.requestId);
      }
    };

    const onTurboFetchRequestError = (rawEvent         )       => {
      if (!active) {
        return;
      }
      const ev = rawEvent

                   ;
      const detail = ev ? ev.detail : undefined;
      const rawUrl =
        detail && detail.url ? String(detail.url) : detail && detail.request ? detail.request.url : undefined;
      const safeUrl = scrubUrl(rawUrl, hooks.redactFields, hooks.allowFields);
      const requestId = normalizeSafeRequestId(
        readHeaderSafely(detail && detail.response ? detail.response.headers : undefined, "x-request-id")
      );
      if (requestId) {
        hooks.onRequestIdChange(requestId);
      }

      const detailErr = detail ? detail.error : undefined;
      const underlying =
        detailErr instanceof Error
          ? detailErr
          : new Error(`Turbo fetch request failed${safeUrl ? ` for ${safeUrl}` : ""}`);
      if (!(detailErr instanceof Error)) {
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
      if (!active) {
        return;
      }
      const ev = rawEvent

                   ;

      const frameId = (ev && ev.target && ev.target.id) || "unknown";
      const response = ev && ev.detail ? ev.detail.response : undefined;
      const status = response ? response.status : undefined;
      const safeUrl = scrubUrl(response ? response.url : undefined, hooks.redactFields, hooks.allowFields);
      const requestId = normalizeSafeRequestId(
        readHeaderSafely(response ? response.headers : undefined, "x-request-id")
      );
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
      active = false;
      if (typeof doc.removeEventListener === "function") {
        doc.removeEventListener("turbo:visit", onTurboVisit);
        doc.removeEventListener("turbo:load", onTurboLoad);
        doc.removeEventListener("turbo:fetch-request-error", onTurboFetchRequestError);
        doc.removeEventListener("turbo:frame-missing", onTurboFrameMissing);
      }
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

    let active = true;
    const originalHandler =
      typeof application.handleError === "function" ? application.handleError.bind(application) : null;

    const wrappedHandler = (error       , message        , detail                          = {})       => {
      if (active) {
        const ctrl = detail.controller                                        ;
        const identifier =
          (typeof detail.identifier === "string" && detail.identifier) ||
          (ctrl && typeof ctrl.identifier === "string" ? ctrl.identifier : undefined);
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
      }

      if (originalHandler) {
        originalHandler(error, message, detail);
      }
    };

    application.handleError = wrappedHandler;

    return () => {
      active = false;
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

    constructor(options                 , scope       ) {
      this.closed = false;
      this.teardowns = [];

      const useRails = options.railsIntegration !== false;
      const railsMeta = useRails ? readRailsMeta() : {};

      const resolvedDsn =
        options.dsn !== undefined ? options.dsn : nullishCoalesce(railsMeta.dsn, null);
      const resolvedEnv = nullishCoalesce(
        options.environment,
        nullishCoalesce(railsMeta.environment, "production")
      );
      const resolvedRelease =
        options.release !== undefined ? options.release : nullishCoalesce(railsMeta.release, null);

      this.options = options;
      this.redactFields = options.redactFields ? [...options.redactFields] : [];
      this.allowFields = options.allowFields ? [...options.allowFields] : [];
      this.config = Object.freeze({
        enabled: nullishCoalesce(options.enabled, true),
        dsn: nullishCoalesce(resolvedDsn, null),
        environment: resolvedEnv,
        release: nullishCoalesce(resolvedRelease, null),
        sampleRate: nullishCoalesce(options.sampleRate, 1.0),
        maxBreadcrumbs: nullishCoalesce(options.maxBreadcrumbs, 20),
        maxStackFrames: nullishCoalesce(options.maxStackFrames, 50)
      });

      scope.trimBreadcrumbs(this.config.maxBreadcrumbs);
      if (railsMeta.requestId && scope.getTag("request_id") === undefined) {
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
            allowFields: this.allowFields,
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
            allowFields: this.allowFields,
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

      const effectiveRelease = nullishCoalesce(partialEvent.release, this.config.release);
      const baseEvent              = {
        ...partialEvent,
        event_id: eventId,
        timestamp: nullishCoalesce(partialEvent.timestamp, new Date().toISOString()),
        platform: "javascript",
        environment: nullishCoalesce(partialEvent.environment, this.config.environment),
        ...(effectiveRelease ? { release: effectiveRelease } : {}),
        sdk: nullishCoalesce(partialEvent.sdk, { name: SDK_NAME, version: VERSION })
      };

      return this.prepareAndSend(baseEvent, scope, {
        ...(hint ? hint : {}),
        event_id: eventId
      });
    }

    isEnabled()          {
      return !this.closed && this.config.enabled && this.parsedDsn !== null && this.transport !== null;
    }

    async flush(timeout = 2000)                   {
      if (!this.transport) {
        return true;
      }
      return this.transport.flush(timeout);
    }

    async close(timeout = 2000)                   {
      this.deactivate();
      return this.flush(timeout);
    }

    deactivate()       {
      this.closed = true;
      this.teardownInstrumentation();
    }

    teardownInstrumentation()       {
      for (const fn of this.teardowns.splice(0)) {
        fn();
      }
    }

            prepareAndSend(event             , scope       , hint                 )         {
      const eventId = event.event_id;
      if (!this.isEnabled() || !this.parsedDsn || !this.transport) {
        return eventId;
      }

      if (this.config.sampleRate <= 0 || (this.config.sampleRate < 1 && Math.random() >= this.config.sampleRate)) {
        return eventId;
      }

      if (!event.request) {
        const g = getGlobalObject()

         ;
        const winHref = g.window && g.window.location ? g.window.location.href : undefined;
        const globalHref = g.location ? g.location.href : undefined;
        const currentHref = winHref !== undefined && winHref !== null ? winHref : globalHref;
        const safeHref = scrubUrl(currentHref, this.redactFields, this.allowFields);
        if (safeHref) {
          event.request = { url: safeHref };
        }
      } else if (event.request.url) {
        event.request = {
          ...event.request,
          url: scrubUrl(event.request.url, this.redactFields, this.allowFields)
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
      const sentId = finalEvent.event_id || eventId;
      if (this === activeClient) {
        lastCapturedEventId = sentId;
      }
      void this.transport.send(envelope);
      return sentId;
    }

            shouldFilterEvent(event             )          {
      const ignoreErrors = this.options.ignoreErrors;
      const excValues = event.exception && event.exception.values ? event.exception.values : [];

      if (ignoreErrors && ignoreErrors.length > 0) {
        const candidates           = [];
        if (event.message) {
          candidates.push(event.message);
        }
        for (const exc of excValues) {
          if (exc.value) {
            candidates.push(exc.value);
            candidates.push(`${exc.type}: ${exc.value}`);
          }
        }
        if (candidates.some((text) => ignoreErrors.some((pat) => matchesPattern(text, pat)))) {
          return true;
        }
      }

      const frames               = [];
      for (const v of excValues) {
        if (v.stacktrace && v.stacktrace.frames) {
          for (const frame of v.stacktrace.frames) {
            frames.push(frame);
          }
        }
      }
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
  let lastCapturedEventId                     = undefined;
  const scopeStack          = [];

  function activeScope()        {
    return scopeStack.length > 0 ? scopeStack[scopeStack.length - 1]  : globalScope;
  }

  function init(options                  = {})                     {
    if (activeClient) {
      activeClient.deactivate();
    }
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
    return activeClient ? activeClient : undefined;
  }

  function isInitialized()          {
    return activeClient !== null;
  }

  function isEnabled()          {
    return activeClient !== null && activeClient.isEnabled();
  }

  function lastEventId()                     {
    return lastCapturedEventId;
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
      return nullishCoalesce(event.event_id, generateEventId());
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
    const client = activeClient;
    activeClient = null;
    lastCapturedEventId = undefined;
    globalScope = new Scope();
    scopeStack.length = 0;
    if (!client) {
      return true;
    }
    return client.close(timeout);
  }

  function resetClient()       {
    if (activeClient) {
      activeClient.deactivate();
    }
    activeClient = null;
    lastCapturedEventId = undefined;
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
    isEnabled,
    lastEventId,
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
