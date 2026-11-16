import { installBrowserInstrumentation } from "./browser.ts";
import { SDK_NAME, VERSION, buildEnvelopeEndpoint, parseDsn, scrubUrl } from "./dsn.ts";
import { generateEventId, serializeEnvelope } from "./envelope.ts";
import { bindStimulusErrorHandler, installRailsTurboInstrumentation, readRailsMeta } from "./rails.ts";
import { Scope } from "./scope.ts";
import { extractExceptionChain } from "./stacktrace.ts";
import { createBrowserTransport } from "./transport.ts";
import type {
  Breadcrumb,
  CaptureContext,
  ParsedDsn,
  SentryEvent,
  SentryEventHint,
  SentraceOptions,
  SeverityLevel,
  StackFrame,
  StimulusApplicationLike,
  Transport,
  User
} from "./types.ts";

export interface FrozenClientConfig {
  readonly enabled: boolean;
  readonly dsn: string | null;
  readonly environment: string;
  readonly release: string | null;
  readonly sampleRate: number;
  readonly maxBreadcrumbs: number;
  readonly maxStackFrames: number;
}

function matchesPattern(value: string, pattern: string | RegExp): boolean {
  if (typeof pattern === "string") {
    return value.includes(pattern);
  }
  return pattern.test(value);
}

export class BrowserClient {
  readonly config: FrozenClientConfig;
  private readonly options: SentraceOptions;
  private readonly parsedDsn: ParsedDsn | null;
  private readonly endpointUrl: string | null;
  private readonly transport: Transport | null;
  private readonly redactFields: string[];
  private closed = false;
  private readonly teardowns: Array<() => void> = [];

  constructor(options: SentraceOptions, scope: Scope) {
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

  recordBreadcrumb(breadcrumb: Breadcrumb, scope: Scope): void {
    if (this.closed || !this.config.enabled) {
      return;
    }

    let candidate: Breadcrumb | null = { ...breadcrumb };
    if (this.options.beforeBreadcrumb) {
      candidate = this.options.beforeBreadcrumb(candidate);
      if (!candidate) {
        return;
      }
    }
    scope.addBreadcrumb(candidate, this.config.maxBreadcrumbs);
  }

  captureException(error: unknown, scope: Scope, captureContext?: CaptureContext): string {
    return this.captureExceptionWithMeta(error, scope, captureContext, {
      handled: true,
      mechanismType: "generic"
    });
  }

  captureExceptionWithMeta(
    error: unknown,
    scope: Scope,
    captureContext: CaptureContext | undefined,
    meta: { handled: boolean; mechanismType: string; fallbackFrame?: StackFrame }
  ): string {
    const syntheticException = error instanceof Error ? undefined : new Error("Synthetic stacktrace");
    const values = extractExceptionChain(
      error,
      this.config.maxStackFrames,
      meta.handled,
      meta.mechanismType,
      syntheticException
    );

    if (meta.fallbackFrame && values.length > 0) {
      const top = values[values.length - 1]!;
      if (!top.stacktrace || top.stacktrace.frames.length === 0) {
        top.stacktrace = { frames: [meta.fallbackFrame] };
      }
    }

    const eventId = generateEventId();
    const baseEvent: SentryEvent = {
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
    message: string,
    scope: Scope,
    levelOrContext?: SeverityLevel | CaptureContext,
    maybeContext?: CaptureContext
  ): string {
    const eventId = generateEventId();
    let explicitLevel: SeverityLevel | undefined;
    let captureContext: CaptureContext | undefined = maybeContext;

    if (typeof levelOrContext === "string") {
      explicitLevel = levelOrContext;
    } else if (levelOrContext !== undefined) {
      captureContext = levelOrContext;
    }

    const baseEvent: SentryEvent = {
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

  captureEvent(partialEvent: Partial<SentryEvent>, scope: Scope, hint?: SentryEventHint): string {
    const eventId =
      partialEvent.event_id && /^[0-9a-f]{32}$/i.test(partialEvent.event_id.replace(/-/g, ""))
        ? partialEvent.event_id.replace(/-/g, "").toLowerCase()
        : generateEventId();

    const baseEvent: SentryEvent = {
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

  async flush(timeout = 2000): Promise<boolean> {
    if (!this.transport) {
      return true;
    }
    return this.transport.flush(timeout);
  }

  async close(timeout = 2000): Promise<boolean> {
    this.closed = true;
    this.teardownInstrumentation();
    return this.flush(timeout);
  }

  teardownInstrumentation(): void {
    for (const fn of this.teardowns.splice(0)) {
      fn();
    }
  }

  private prepareAndSend(event: SentryEvent, scope: Scope, hint: SentryEventHint): string {
    const eventId = event.event_id;
    if (this.closed || !this.config.enabled || !this.parsedDsn || !this.transport) {
      return eventId;
    }

    if (this.config.sampleRate <= 0 || (this.config.sampleRate < 1 && Math.random() >= this.config.sampleRate)) {
      return eventId;
    }

    if (!event.request) {
      const currentHref = (globalThis as { window?: { location?: { href?: string } }; location?: { href?: string } })
        .window?.location?.href ?? (globalThis as { location?: { href?: string } }).location?.href;
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

    let finalEvent: SentryEvent | null = event;
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

  private shouldFilterEvent(event: SentryEvent): boolean {
    const ignoreErrors = this.options.ignoreErrors;
    if (ignoreErrors && ignoreErrors.length > 0) {
      const candidates: string[] = [];
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
      const denied = filenames.some((url) => this.options.denyUrls!.some((pat) => matchesPattern(url, pat)));
      if (denied) {
        return true;
      }
    }

    if (this.options.allowUrls && this.options.allowUrls.length > 0 && filenames.length > 0) {
      const allowed = filenames.some((url) => this.options.allowUrls!.some((pat) => matchesPattern(url, pat)));
      if (!allowed) {
        return true;
      }
    }

    return false;
  }
}

// Singleton hub state
let activeClient: BrowserClient | null = null;
let globalScope = new Scope();
const scopeStack: Scope[] = [];

function activeScope(): Scope {
  return scopeStack.length > 0 ? scopeStack[scopeStack.length - 1]! : globalScope;
}

export function init(options: SentraceOptions = {}): FrozenClientConfig {
  if (activeClient) {
    activeClient.teardownInstrumentation();
  }
  globalScope = new Scope();
  scopeStack.length = 0;
  activeClient = new BrowserClient(options, globalScope);
  return activeClient.config;
}

export function initRails(options: SentraceOptions = {}): FrozenClientConfig {
  return init({ ...options, railsIntegration: true });
}

export function getConfig(): FrozenClientConfig | null {
  return activeClient ? activeClient.config : null;
}

export function getClient(): BrowserClient | undefined {
  return activeClient ?? undefined;
}

export function isInitialized(): boolean {
  return activeClient !== null;
}

export function getCurrentScope(): Scope {
  return activeScope();
}

export function getGlobalScope(): Scope {
  return globalScope;
}

export function getIsolationScope(): Scope {
  return activeScope();
}

export function withScope<T>(callback: (scope: Scope) => T): T {
  const forked = activeScope().clone();
  scopeStack.push(forked);
  try {
    return callback(forked);
  } finally {
    scopeStack.pop();
  }
}

export function captureException(error: unknown, captureContext?: CaptureContext): string {
  if (!activeClient) {
    return generateEventId();
  }
  return activeClient.captureException(error, activeScope(), captureContext);
}

export function captureMessage(
  message: string,
  levelOrContext?: SeverityLevel | CaptureContext,
  maybeContext?: CaptureContext
): string {
  if (!activeClient) {
    return generateEventId();
  }
  return activeClient.captureMessage(message, activeScope(), levelOrContext, maybeContext);
}

export function captureEvent(event: Partial<SentryEvent>, hint?: SentryEventHint): string {
  if (!activeClient) {
    return event.event_id ?? generateEventId();
  }
  return activeClient.captureEvent(event, activeScope(), hint);
}

export function addBreadcrumb(breadcrumb: Breadcrumb): void {
  if (activeClient) {
    activeClient.recordBreadcrumb(breadcrumb, activeScope());
  } else {
    activeScope().addBreadcrumb(breadcrumb);
  }
}

export function clearBreadcrumbs(): void {
  activeScope().clearBreadcrumbs();
}

export function setTag(key: string, value: string | number | boolean): void {
  activeScope().setTag(key, value);
}

export function setTags(tags: Record<string, string | number | boolean>): void {
  activeScope().setTags(tags);
}

export function setUser(user: User | null): void {
  activeScope().setUser(user);
}

export function setContext(name: string, context: Record<string, unknown> | null): void {
  activeScope().setContext(name, context);
}

export function setExtra(key: string, extra: unknown): void {
  activeScope().setExtra(key, extra);
}

export function setExtras(extras: Record<string, unknown>): void {
  activeScope().setExtras(extras);
}

export async function flush(timeout = 2000): Promise<boolean> {
  if (!activeClient) {
    return true;
  }
  return activeClient.flush(timeout);
}

export async function close(timeout = 2000): Promise<boolean> {
  if (!activeClient) {
    return true;
  }
  const client = activeClient;
  activeClient = null;
  return client.close(timeout);
}

export function resetClient(): void {
  if (activeClient) {
    activeClient.teardownInstrumentation();
  }
  activeClient = null;
  globalScope = new Scope();
  scopeStack.length = 0;
}

export function registerStimulusErrorHandler(application: StimulusApplicationLike): () => void {
  return bindStimulusErrorHandler(application, captureException);
}
