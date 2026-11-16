export type SentraceLevel = "debug" | "info" | "warning" | "error" | "fatal";

export interface SentraceOptions {
  dsn?: string | null;
  environment?: string;
  release?: string | null;
  enabled?: boolean;
}

export interface SentraceBreadcrumb {
  category?: string;
  level?: SentraceLevel;
  message: string;
  timestamp?: string;
  data?: Record<string, unknown>;
}

export interface SentraceCaptureContext {
  tags?: Record<string, string>;
  contexts?: Record<string, Record<string, unknown>>;
  user?: { id?: string };
  fingerprint?: string[];
}

export declare const VERSION = "0.0.1";

export declare function init(options?: SentraceOptions): Readonly<Required<SentraceOptions>>;
export declare function getConfig(): Readonly<Required<SentraceOptions>> | null;
export declare function captureException(error: unknown, context?: SentraceCaptureContext): string | null;
export declare function captureMessage(
  message: string,
  level?: SentraceLevel,
  context?: SentraceCaptureContext
): string | null;
export declare function addBreadcrumb(breadcrumb: SentraceBreadcrumb): void;
export declare function resetClient(): void;

declare const Sentrace: {
  readonly VERSION: typeof VERSION;
  init: typeof init;
  getConfig: typeof getConfig;
  captureException: typeof captureException;
  captureMessage: typeof captureMessage;
  addBreadcrumb: typeof addBreadcrumb;
  resetClient: typeof resetClient;
};

export default Sentrace;
