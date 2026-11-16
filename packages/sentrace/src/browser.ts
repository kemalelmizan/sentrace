import { getGlobalObject, scrubUrl } from "./dsn.ts";
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
      const ev = rawEvent as
        | {
            error?: unknown;
            message?: string;
            filename?: string;
            lineno?: number;
            colno?: number;
          }
        | undefined;
      const err =
        ev && ev.error !== undefined && ev.error !== null
          ? ev.error
          : new Error((ev && ev.message) || "Uncaught window error");
      const fallbackFrame: StackFrame | undefined =
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

    const rejectionListener = (rawEvent: unknown): void => {
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
          historyObj[methodName] = function patchedHistory(...args: unknown[]): unknown {
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
          cleanups.push(() => {
            historyObj[methodName] = original;
          });
        }
      }
    }
  }

  if (doc && typeof doc.addEventListener === "function" && typeof doc.removeEventListener === "function") {
    const clickListener = (rawEvent: unknown): void => {
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
      if (init && init[SENTRACE_INTERNAL_FETCH_FLAG]) {
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
          let requestId: string | undefined;
          if (response && response.headers && typeof response.headers.get === "function") {
            const rawHeader = response.headers.get("x-request-id");
            requestId = rawHeader !== null && rawHeader !== undefined ? rawHeader : undefined;
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
        (networkErr: unknown) => {
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

    proto.open = function sentraceXhrOpen(
      this: Record<string, unknown>,
      method: string,
      url: string | URL,
      ...rest: unknown[]
    ): unknown {
      this.__sentraceXhrMeta = {
        method: String(method || "GET").toUpperCase(),
        url: String(url || "")
      };
      return origOpen.call(this, method, url, ...rest);
    };

    proto.send = function sentraceXhrSend(this: Record<string, unknown>, body?: unknown): unknown {
      const meta = this.__sentraceXhrMeta as { method: string; url: string } | undefined;
      if (meta && !isInternalEndpoint(meta.url, hooks.endpointUrl)) {
        const onLoadEnd = (): void => {
          const status = typeof this.status === "number" ? this.status : undefined;
          const getHeader = this.getResponseHeader as ((name: string) => string | null) | undefined;
          let requestId: string | undefined;
          if (typeof getHeader === "function") {
            try {
              const rawHeader = getHeader.call(this, "x-request-id");
              requestId = rawHeader !== null && rawHeader !== undefined ? rawHeader : undefined;
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

        const addListener = this.addEventListener as ((type: string, fn: () => void) => void) | undefined;
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
      } catch (_err) {
        // Ignore teardown errors
      }
    }
  };
}
