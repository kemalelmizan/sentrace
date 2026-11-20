import { SDK_NAME, VERSION, formatPublicDsn, getGlobalObject } from "./dsn.ts";
import type { ParsedDsn, SentryEvent } from "./types.ts";

export function generateEventId(): string {
  const g = getGlobalObject() as {
    crypto?: {
      randomUUID?: () => string;
      getRandomValues?: (buf: Uint8Array) => Uint8Array;
    };
  };

  if (g.crypto && typeof g.crypto.randomUUID === "function") {
    return g.crypto.randomUUID().replace(/-/g, "").toLowerCase();
  }

  if (g.crypto && typeof g.crypto.getRandomValues === "function") {
    const bytes = g.crypto.getRandomValues(new Uint8Array(16));
    let hex = "";
    for (let i = 0; i < bytes.length; i += 1) {
      hex += bytes[i]!.toString(16).padStart(2, "0");
    }
    return hex;
  }

  let fallback = "";
  for (let i = 0; i < 32; i += 1) {
    fallback += Math.floor(Math.random() * 16).toString(16);
  }
  return fallback;
}

function safeJsonStringify(value: unknown): string {
  const ancestors: object[] = [];
  return JSON.stringify(value, function (_key: string, val: unknown): unknown {
    if (typeof val !== "object" || val === null) {
      return val;
    }
    while (ancestors.length > 0 && ancestors[ancestors.length - 1] !== this) {
      ancestors.pop();
    }
    if (ancestors.indexOf(val) !== -1) {
      return "[Circular]";
    }
    ancestors.push(val);
    return val;
  });
}

/**
 * Serializes a normalized `SentryEvent` into a standard 3-line Sentry v7 Envelope.
 */
export function serializeEnvelope(event: SentryEvent, dsn: ParsedDsn): string {
  const envelopeHeader = JSON.stringify({
    event_id: event.event_id,
    sent_at: new Date().toISOString(),
    dsn: formatPublicDsn(dsn),
    sdk: {
      name: SDK_NAME,
      version: VERSION
    }
  });

  const payload = safeJsonStringify(event);
  const byteLength =
    typeof TextEncoder !== "undefined" ? new TextEncoder().encode(payload).byteLength : payload.length;
  const itemHeader = JSON.stringify({
    type: "event",
    content_type: "application/json",
    length: byteLength
  });

  return `${envelopeHeader}\n${itemHeader}\n${payload}\n`;
}
