import { getGlobalObject, isSameOrAllowedOrigin, normalizeSafeRequestId, scrubUrl } from "./dsn.ts";
import { SENTRACE_INTERNAL_FETCH_FLAG } from "./transport.ts";
import type { Breadcrumb, StackFrame } from "./types.ts";

export interface BrowserInstrumentationHooks {
  endpointUrl: string | null;
  redactFields: string[];
  allowFields?: string[];
  onError: (
    error: unknown,
    options: { handled: boolean; mechanismType: string; fallbackFrame?: StackFrame }
  ) => void;
  onBreadcrumb: (breadcrumb: Breadcrumb) => void;
  onCorrelatedRequestId: (requestId: string) => void;
}

function describeElement(target: unknown): string {
  if (!target || typeof target !== "object") {
    return "<unknown>";
  }
  const el = target as {
    tagName?: string;
    id?: string;
    className?: unknown;
    getAttribute?: (attr: string) => string | null;
  };
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

function isInternalEndpoint(url: string, endpointUrl: string | null): boolean {
  if (!endpointUrl || !url) {
    return false;
  }
  const baseEndpoint = endpointUrl.split("?")[0]!;
  return url.startsWith(baseEndpoint);
}

export function installBrowserInstrumentation(hooks: BrowserInstrumentationHooks): () => void {
  let active = true;
  const cleanups: Array<() => void> = [];
  const g = getGlobalObject();
  const win = (g.window !== undefined && g.window !== null ? g.window : g) as {
    addEventListener?: (type: string, listener: (ev: unknown) => void, options?: boolean) => void;
    removeEventListener?: (type: string, listener: (ev: unknown) => void, options?: boolean) => void;
    location?: { href?: string };
    history?: {
      pushState?: (...args: unknown[]) => unknown;
      replaceState?: (...args: unknown[]) => unknown;
    };
  };
  const doc = g.document as
    | {
      addEventListener?: (type: string, listener: (ev: unknown) => void, options?: boolean) => void;
      removeEventListener?: (type: string, listener: (ev: unknown) => void, options?: boolean) => void;
    }
    | undefined;

  if (win && typeof win.addEventListener === "function" && typeof win.removeEventListener === "function") {
    const errorListener = (rawEvent: unknown): void => {
      if (!active) {
        return;
      }
      const ev = rawEvent as
        | {
          error?: unknown;
          message?: string;
          filename?: string;
          lineno?: number;
          colno?: number;
        }
        | undefined;
      let err: unknown;
      if (ev && ev.error !== undefined && ev.error !== null) {
        err = ev.error;
      } else {
        const syntheticErr = new Error((ev && ev.message) || "Uncaught window error");
        if (ev && ev.filename) {
          syntheticErr.stack = "";
        }
        err = syntheticErr;
      }
      const safeErrorFilename =
        ev && ev.filename ? scrubUrl(ev.filename, hooks.redactFields, hooks.allowFields) || ev.filename : undefined;
      const fallbackFrame: StackFrame | undefined =
        safeErrorFilename
          ? {
            filename: safeErrorFilename,
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

    const rejectionListener = (rawEvent: unknown): void => {
      if (!active) {
        return;
      }
      const ev = rawEvent as { reason?: unknown } | undefined;
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
    const popstateListener = (): void => {
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
      for (const methodName of ["pushState", "replaceState"] as const) {
        const original = historyObj[methodName];
        if (typeof original === "function") {
          const wrappedHistory = function patchedHistory(...args: unknown[]): unknown {
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
    const clickListener = (rawEvent: unknown): void => {
      if (!active) {
        return;
      }
      const ev = rawEvent as { target?: unknown } | undefined;
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
    const originalFetch = g.fetch as typeof fetch;
    const wrappedFetch = function sentraceFetch(
      input: RequestInfo | URL,
      init?: RequestInit & { [SENTRACE_INTERNAL_FETCH_FLAG]?: boolean }
    ): Promise<Response> {
      if (!active || (init && init[SENTRACE_INTERNAL_FETCH_FLAG])) {
        return originalFetch.call(g, input, init);
      }

      const inputObj = typeof input === "object" && input !== null ? (input as { url?: unknown; method?: unknown }) : null;
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
          let requestId: string | undefined;
          if (response && response.headers && typeof response.headers.get === "function") {
            requestId = normalizeSafeRequestId(response.headers.get("x-request-id"));
          }
          const status = response && typeof response.status === "number" ? response.status : undefined;

          if (
            requestId &&
            status !== undefined &&
            status >= 400 &&
            isSameOrAllowedOrigin(rawUrl, hooks.endpointUrl, win.location ? win.location.href : undefined)
          ) {
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
        (networkErr: unknown) => {
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

  const XhrCtor = g.XMLHttpRequest as
    | {
      prototype?: {
        open?: (method: string, url: string | URL, ...rest: unknown[]) => unknown;
        send?: (body?: unknown) => unknown;
      };
    }
    | undefined;

  if (
    XhrCtor &&
    XhrCtor.prototype &&
    typeof XhrCtor.prototype.open === "function" &&
    typeof XhrCtor.prototype.send === "function"
  ) {
    const proto = XhrCtor.prototype;
    const origOpen = proto.open!;
    const origSend = proto.send!;

    const wrappedOpen = function sentraceXhrOpen(
      this: Record<string, unknown>,
      method: string,
      url: string | URL,
      ...rest: unknown[]
    ): unknown {
      if (active) {
        this.__sentraceXhrMeta = {
          method: String(method || "GET").toUpperCase(),
          url: String(url || "")
        };
      }
      return origOpen.call(this, method, url, ...rest);
    };

    const wrappedSend = function sentraceXhrSend(this: Record<string, unknown>, body?: unknown): unknown {
      if (!active) {
        return origSend.call(this, body);
      }
      const meta = this.__sentraceXhrMeta as { method: string; url: string } | undefined;
      if (meta && !isInternalEndpoint(meta.url, hooks.endpointUrl)) {
        const onLoadEnd = (): void => {
          if (!active) {
            return;
          }
          const status = typeof this.status === "number" ? this.status : undefined;
          const getHeader = this.getResponseHeader as ((name: string) => string | null) | undefined;
          let requestId: string | undefined;
          if (typeof getHeader === "function") {
            try {
              requestId = normalizeSafeRequestId(getHeader.call(this, "x-request-id"));
            } catch (_err) {
              requestId = undefined;
            }
          }

          if (
            requestId &&
            status !== undefined &&
            status >= 400 &&
            isSameOrAllowedOrigin(meta.url, hooks.endpointUrl, win.location ? win.location.href : undefined)
          ) {
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

        const addListener = this.addEventListener as ((type: string, fn: () => void) => void) | undefined;
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
