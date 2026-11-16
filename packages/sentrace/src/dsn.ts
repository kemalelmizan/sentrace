import type { ParsedDsn } from "./types.ts";

export const VERSION = "0.1.0";
export const SDK_NAME = "sentrace.javascript.browser";
export const SDK_CLIENT = `sentrace-js/${VERSION}`;

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

  const projectId = segments.pop()!;
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

export function formatPublicDsn(dsn: ParsedDsn): string {
  const authority = dsn.port ? `${dsn.host}:${dsn.port}` : dsn.host;
  return `${dsn.protocol}://${encodeURIComponent(dsn.publicKey)}@${authority}${dsn.pathPrefix}/${dsn.projectId}`;
}

export function buildEnvelopeEndpoint(dsn: ParsedDsn): string {
  const authority = dsn.port ? `${dsn.host}:${dsn.port}` : dsn.host;
  const query = `sentry_key=${encodeURIComponent(dsn.publicKey)}&sentry_version=7&sentry_client=${encodeURIComponent(SDK_CLIENT)}`;
  return `${dsn.protocol}://${authority}${dsn.pathPrefix}/api/${dsn.projectId}/envelope?${query}`;
}

export function scrubUrl(rawUrl: string | undefined, extraRedactFields: string[] = []): string | undefined {
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

  const isSensitive = (key: string): boolean => {
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
