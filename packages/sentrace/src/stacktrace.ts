import { scrubUrl } from "./dsn.ts";
import type { SentryExceptionValue, StackFrame } from "./types.ts";

const MAX_STACK_LINE_CHARS = 4096;
const MAX_STACK_LINES_SCANNED = 250;

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

function extractLineColSuffix(text: string): { file: string; lineno: number; colno: number } | null {
  const colSep = text.lastIndexOf(":");
  if (colSep <= 0) {
    return null;
  }
  const lineSep = text.lastIndexOf(":", colSep - 1);
  if (lineSep <= 0) {
    return null;
  }
  const colStr = text.slice(colSep + 1);
  const lineStr = text.slice(lineSep + 1, colSep);
  if (!/^\d+$/.test(lineStr) || !/^\d+$/.test(colStr)) {
    return null;
  }
  const file = text.slice(0, lineSep).trim();
  if (!file) {
    return null;
  }
  return {
    file,
    lineno: Number.parseInt(lineStr, 10),
    colno: Number.parseInt(colStr, 10)
  };
}

function sanitizeFrameFilename(rawFilename: string): string {
  if (
    /^[a-zA-Z][a-zA-Z\d+\-.]*:\/\//.test(rawFilename) ||
    rawFilename.indexOf("?") !== -1 ||
    rawFilename.indexOf("#") !== -1
  ) {
    const scrubbed = scrubUrl(rawFilename);
    return scrubbed || rawFilename;
  }
  return rawFilename;
}

export function parseStackLine(line: string): StackFrame | null {
  if (!line || line.length > MAX_STACK_LINE_CHARS) {
    return null;
  }
  const trimmed = line.trim();
  if (!trimmed || trimmed.length > MAX_STACK_LINE_CHARS || trimmed.includes("[native code]")) {
    return null;
  }

  if (trimmed.startsWith("at ")) {
    let rest = trimmed.slice(3).trim();
    if (rest.startsWith("async ")) {
      rest = rest.slice(6).trim();
    }

    if (rest.endsWith(")") && rest.indexOf(" (") !== -1) {
      const openParen = rest.indexOf(" (");
      let fnRaw = rest.slice(0, openParen).trim();
      if (fnRaw.startsWith("new ")) {
        fnRaw = fnRaw.slice(4).trim();
      }
      let locPart = rest.slice(openParen + 2, rest.length - 1).trim();
      if (locPart.startsWith("eval at ")) {
        const innerOpen = locPart.indexOf(" (");
        if (innerOpen !== -1 && locPart.endsWith(")")) {
          locPart = locPart.slice(innerOpen + 2, locPart.length - 1).trim();
        }
      }
      const parsedParen = extractLineColSuffix(locPart);
      if (parsedParen) {
        const cleanFile = sanitizeFrameFilename(parsedParen.file);
        return {
          filename: cleanFile,
          function: cleanFunctionName(fnRaw),
          lineno: parsedParen.lineno,
          colno: parsedParen.colno,
          in_app: isInAppFilename(cleanFile)
        };
      }
    }

    const parsedBare = extractLineColSuffix(rest);
    if (parsedBare) {
      const cleanBareFile = sanitizeFrameFilename(parsedBare.file);
      return {
        filename: cleanBareFile,
        function: "?",
        lineno: parsedBare.lineno,
        colno: parsedBare.colno,
        in_app: isInAppFilename(cleanBareFile)
      };
    }

    return null;
  }

  const atIdx = trimmed.indexOf("@");
  const fnPart = atIdx !== -1 ? trimmed.slice(0, atIdx) : undefined;
  const locPart = atIdx !== -1 ? trimmed.slice(atIdx + 1).trim() : trimmed;
  const parsedGecko = extractLineColSuffix(locPart);
  if (
    parsedGecko &&
    (parsedGecko.file.includes("/") || parsedGecko.file.includes(".") || parsedGecko.file.startsWith("http"))
  ) {
    const cleanGeckoFile = sanitizeFrameFilename(parsedGecko.file);
    return {
      filename: cleanGeckoFile,
      function: cleanFunctionName(fnPart),
      lineno: parsedGecko.lineno,
      colno: parsedGecko.colno,
      in_app: isInAppFilename(cleanGeckoFile)
    };
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
  const rawLines = stack.split(/\r?\n/);
  const scanLimit = Math.min(rawLines.length, MAX_STACK_LINES_SCANNED);
  for (let i = 0; i < scanLimit; i += 1) {
    const frame = parseStackLine(rawLines[i]!);
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
