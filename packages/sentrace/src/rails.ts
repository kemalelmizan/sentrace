import { scrubUrl } from "./dsn.ts";
import type {
  Breadcrumb,
  CaptureContext,
  RailsMetaConfig,
  StimulusApplicationLike
} from "./types.ts";

interface MetaQueryDocument {
  querySelector?: (selector: string) => { getAttribute?: (name: string) => string | null; content?: string } | null;
  getElementsByTagName?: (
    tag: string
  ) => ArrayLike<{ getAttribute?: (name: string) => string | null; name?: string; content?: string }>;
  addEventListener?: (type: string, listener: (ev: unknown) => void) => void;
  removeEventListener?: (type: string, listener: (ev: unknown) => void) => void;
}

function readMetaTagContent(doc: MetaQueryDocument | undefined, metaName: string): string | undefined {
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
      const item = metas[i]!;
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
export function readRailsMeta(customDoc?: unknown): RailsMetaConfig {
  const doc = (customDoc ?? (globalThis as { document?: unknown }).document) as MetaQueryDocument | undefined;
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

export interface RailsIntegrationHooks {
  redactFields: string[];
  onBreadcrumb: (breadcrumb: Breadcrumb) => void;
  onRequestIdChange: (requestId: string) => void;
  captureException: (error: unknown, context?: CaptureContext) => string;
}

/**
 * Attaches Hotwire Turbo lifecycle and error listeners (`turbo:visit`, `turbo:load`,
 * `turbo:fetch-request-error`, `turbo:frame-missing`).
 */
export function installRailsTurboInstrumentation(
  hooks: RailsIntegrationHooks,
  customDoc?: unknown
): () => void {
  const doc = (customDoc ?? (globalThis as { document?: unknown }).document) as MetaQueryDocument | undefined;
  if (!doc || typeof doc.addEventListener !== "function" || typeof doc.removeEventListener !== "function") {
    return () => {};
  }

  const onTurboVisit = (rawEvent: unknown): void => {
    const detail = (rawEvent as { detail?: { url?: string; action?: string } })?.detail;
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

  const onTurboLoad = (): void => {
    const refreshed = readRailsMeta(doc);
    if (refreshed.requestId) {
      hooks.onRequestIdChange(refreshed.requestId);
    }
  };

  const onTurboFetchRequestError = (rawEvent: unknown): void => {
    const ev = rawEvent as {
      detail?: {
        url?: string | URL;
        error?: unknown;
        request?: { url?: string };
        response?: { statusCode?: number; responseHTML?: unknown; headers?: { get?: (k: string) => string | null } };
      };
    };
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

  const onTurboFrameMissing = (rawEvent: unknown): void => {
    const ev = rawEvent as {
      target?: { id?: string };
      detail?: {
        response?: {
          url?: string;
          status?: number;
          headers?: { get?: (k: string) => string | null };
        };
      };
    };

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
export function bindStimulusErrorHandler(
  application: StimulusApplicationLike,
  captureFn: (error: unknown, context?: CaptureContext) => string
): () => void {
  if (!application || typeof application !== "object") {
    return () => {};
  }

  const originalHandler =
    typeof application.handleError === "function" ? application.handleError.bind(application) : null;

  const wrappedHandler = (error: Error, message: string, detail: Record<string, unknown> = {}): void => {
    const identifier =
      (typeof detail.identifier === "string" && detail.identifier) ||
      (typeof (detail.controller as { identifier?: string } | undefined)?.identifier === "string"
        ? (detail.controller as { identifier: string }).identifier
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
