import type { SentryExceptionValue, StackFrame } from "./types.ts";

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

export function isInAppFilename(filename: string | undefined): boolean {
  if (!filename) {
    return false;
  }
  if (filename === "<anonymous>" || filename === "[native code]" || filename.startsWith("node:")) {
    return false;
  }
  const lower = filename.toLowerCase();
  return !NON_APP_URL_PATTERNS.some((pattern) => lower.includes(pattern));
}

function cleanFunctionName(raw: string | undefined): string {
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

export function parseStackLine(line: string): StackFrame | null {
  const trimmed = line.trim();
  if (!trimmed || trimmed.includes("[native code]")) {
    return null;
  }

  let match = V8_FRAME_WITH_PARENS.exec(trimmed);
  if (match) {
    const filename = match[2]!.trim();
    return {
      filename,
      function: cleanFunctionName(match[1]),
      lineno: Number.parseInt(match[3]!, 10),
      colno: Number.parseInt(match[4]!, 10),
      in_app: isInAppFilename(filename)
    };
  }

  match = V8_BARE_FRAME.exec(trimmed);
  if (match) {
    const filename = match[1]!.trim();
    return {
      filename,
      function: "?",
      lineno: Number.parseInt(match[2]!, 10),
      colno: Number.parseInt(match[3]!, 10),
      in_app: isInAppFilename(filename)
    };
  }

  if (!trimmed.startsWith("at ")) {
    match = GECKO_WEBKIT_FRAME.exec(trimmed);
    if (match) {
      const filename = match[2]!.trim();
      if (filename.includes("/") || filename.includes(".") || filename.startsWith("http")) {
        return {
          filename,
          function: cleanFunctionName(match[1]),
          lineno: Number.parseInt(match[3]!, 10),
          colno: Number.parseInt(match[4]!, 10),
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
export function parseStackFrames(stack: string | undefined, maxFrames = 50): StackFrame[] {
  if (!stack || typeof stack !== "string") {
    return [];
  }

  const newestFirst: StackFrame[] = [];
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
  err: unknown,
  maxFrames: number,
  handled: boolean,
  mechanismType: string
): SentryExceptionValue {
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
    const obj = err as Record<string, unknown>;
    const ctor = obj.constructor as { name?: unknown } | undefined;
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
export function extractExceptionChain(
  error: unknown,
  maxFrames = 50,
  handled = true,
  mechanismType = "generic",
  syntheticException?: Error
): SentryExceptionValue[] {
  const chain: SentryExceptionValue[] = [];
  const seen = new Set<unknown>();
  let current: unknown = error;
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
      current = (current as { cause?: unknown }).cause;
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
