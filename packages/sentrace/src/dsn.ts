import type { ParsedDsn } from "./types.ts";

export const VERSION = "0.1.5";
export const SDK_NAME = "sentrace.javascript.browser";
export const SDK_CLIENT = `sentrace-js/${VERSION}`;

export function getGlobalObject(): Record<string, unknown> {
  if (typeof globalThis !== "undefined") {
    return globalThis as unknown as Record<string, unknown>;
  }
  if (typeof window !== "undefined") {
    return window as unknown as Record<string, unknown>;
  }
  if (typeof self !== "undefined") {
    return self as unknown as Record<string, unknown>;
  }
  return {};
}

export function nullishCoalesce<T>(value: T | null | undefined, fallback: T): T {
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

export function normalizeSafeRequestId(rawValue: unknown): string | undefined {
  if (typeof rawValue !== "string") {
    return undefined;
  }
  const trimmed = rawValue.trim();
  return SAFE_REQUEST_ID_REGEX.test(trimmed) ? trimmed : undefined;
}

export function parseDsn(rawDsn: string | null | undefined): ParsedDsn | null {
  if (!rawDsn || typeof rawDsn !== "string") {
    return null;
  }

  const trimmed = rawDsn.trim();
  if (!trimmed) {
    return null;
  }

  let uri: URL;
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

  const projectId = segments.pop()!;
  if (!/^[1-9]\d*$/.test(projectId)) {
    return null;
  }

  let decodedPublicKey: string;
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

export function formatPublicDsn(dsn: ParsedDsn): string {
  const authority = dsn.port ? `${dsn.host}:${dsn.port}` : dsn.host;
  return `${dsn.protocol}://${encodeURIComponent(dsn.publicKey)}@${authority}${dsn.pathPrefix}/${dsn.projectId}`;
}

export function buildEnvelopeEndpoint(dsn: ParsedDsn): string {
  const authority = dsn.port ? `${dsn.host}:${dsn.port}` : dsn.host;
  const query = `sentry_key=${encodeURIComponent(dsn.publicKey)}&sentry_version=7&sentry_client=${encodeURIComponent(SDK_CLIENT)}`;
  return `${dsn.protocol}://${authority}${dsn.pathPrefix}/api/${dsn.projectId}/envelope?${query}`;
}

export function isSameOrAllowedOrigin(
  rawUrl: string | undefined,
  endpointUrl: string | null,
  pageHref: string | undefined
): boolean {
  if (!rawUrl || typeof rawUrl !== "string") {
    return false;
  }
  const trimmed = rawUrl.trim();
  if (!trimmed) {
    return false;
  }
  if (!/^[a-zA-Z][a-zA-Z\d+\-.]*:\/\//.test(trimmed) && !trimmed.startsWith("//")) {
    return true;
  }

  try {
    const targetOrigin = new URL(trimmed, pageHref || "http://localhost").origin;
    if (pageHref) {
      try {
        if (new URL(pageHref).origin === targetOrigin) {
          return true;
        }
      } catch (_err) {
        // Ignore invalid pageHref
      }
    }
    if (endpointUrl) {
      try {
        if (new URL(endpointUrl).origin === targetOrigin) {
          return true;
        }
      } catch (_err) {
        // Ignore invalid endpointUrl
      }
    }
    return false;
  } catch (_err) {
    return false;
  }
}

export function scrubUrl(
  rawUrl: string | undefined,
  extraRedactFields: string[] = [],
  allowFields: string[] = []
): string | undefined {
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

  const isSensitive = (key: string): boolean => {
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
    parsed.hash = "";

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
      return `${parsed.pathname}${parsed.search}`;
    }
    return parsed.toString();
  } catch (_err) {
    const withoutQueryOrHash = trimmed.split(/[?#]/)[0];
    return withoutQueryOrHash ? withoutQueryOrHash.replace(/\/\/[^/@]+@/, "//") : trimmed;
  }
}
