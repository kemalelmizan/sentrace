import type {
  Breadcrumb,
  CaptureContext,
  ScopeLike,
  SentryEvent,
  SeverityLevel,
  User
} from "./types.ts";

function isUnsafeScopeKey(key: string): boolean {
  return key === "__proto__" || key === "constructor" || key === "prototype";
}

export class Scope implements ScopeLike {
  declare private tags: Record<string, string>;
  declare private user: User | null;
  declare private contexts: Record<string, Record<string, unknown>>;
  declare private extra: Record<string, unknown>;
  declare private breadcrumbs: Breadcrumb[];
  declare private fingerprint: string[] | undefined;
  declare private level: SeverityLevel | undefined;

  constructor() {
    this.tags = {};
    this.user = null;
    this.contexts = {};
    this.extra = {};
    this.breadcrumbs = [];
    this.fingerprint = undefined;
    this.level = undefined;
  }

  setTag(key: string, value: string | number | boolean): this {
    const normalizedKey = String(key);
    if (!isUnsafeScopeKey(normalizedKey)) {
      this.tags[normalizedKey] = String(value);
    }
    return this;
  }

  setTags(tags: Record<string, string | number | boolean>): this {
    for (const [k, v] of Object.entries(tags)) {
      if (!isUnsafeScopeKey(k) && v !== undefined && v !== null) {
        this.tags[k] = String(v);
      }
    }
    return this;
  }

  getTag(key: string): string | undefined {
    if (isUnsafeScopeKey(key) || !Object.prototype.hasOwnProperty.call(this.tags, key)) {
      return undefined;
    }
    return this.tags[key];
  }

  setUser(user: User | null): this {
    this.user = user ? { ...user } : null;
    return this;
  }

  setContext(name: string, context: Record<string, unknown> | null): this {
    if (isUnsafeScopeKey(name)) {
      return this;
    }
    if (context === null) {
      delete this.contexts[name];
    } else {
      const cleaned: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(context)) {
        if (!isUnsafeScopeKey(k)) {
          cleaned[k] = v;
        }
      }
      this.contexts[name] = cleaned;
    }
    return this;
  }

  setExtra(key: string, extra: unknown): this {
    if (!isUnsafeScopeKey(key)) {
      this.extra[key] = extra;
    }
    return this;
  }

  setExtras(extras: Record<string, unknown>): this {
    for (const [k, v] of Object.entries(extras)) {
      if (!isUnsafeScopeKey(k)) {
        this.extra[k] = v;
      }
    }
    return this;
  }

  setLevel(level: SeverityLevel): this {
    this.level = level;
    return this;
  }

  setFingerprint(fingerprint: string[]): this {
    this.fingerprint = [...fingerprint];
    return this;
  }

  addBreadcrumb(breadcrumb: Breadcrumb, maxBreadcrumbs = 20): this {
    if (maxBreadcrumbs <= 0) {
      return this;
    }

    const normalized: Breadcrumb = {
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

  clearBreadcrumbs(): this {
    this.breadcrumbs = [];
    return this;
  }

  trimBreadcrumbs(maxBreadcrumbs: number): this {
    if (maxBreadcrumbs <= 0) {
      this.breadcrumbs = [];
      return this;
    }
    if (this.breadcrumbs.length > maxBreadcrumbs) {
      this.breadcrumbs.splice(0, this.breadcrumbs.length - maxBreadcrumbs);
    }
    return this;
  }

  clear(): this {
    this.tags = {};
    this.user = null;
    this.contexts = {};
    this.extra = {};
    this.breadcrumbs = [];
    this.fingerprint = undefined;
    this.level = undefined;
    return this;
  }

  clone(): Scope {
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

  applyCaptureContext(context?: CaptureContext): this {
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

  applyToEvent(event: SentryEvent, maxBreadcrumbs: number): SentryEvent {
    const mergedTags = { ...this.tags, ...(event.tags ? event.tags : {}) };
    if (Object.keys(mergedTags).length > 0) {
      event.tags = mergedTags;
    }

    const mergedExtra = { ...this.extra, ...(event.extra ? event.extra : {}) };
    if (Object.keys(mergedExtra).length > 0) {
      event.extra = mergedExtra;
    }

    const mergedContexts: Record<string, Record<string, unknown>> = {};
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
