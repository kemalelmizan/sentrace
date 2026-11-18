export {
  SDK_CLIENT,
  SDK_NAME,
  VERSION,
  buildEnvelopeEndpoint,
  formatPublicDsn,
  parseDsn,
  scrubUrl
} from "./dsn.ts";
export { generateEventId, serializeEnvelope } from "./envelope.ts";
export { readRailsMeta } from "./rails.ts";
export { Scope } from "./scope.ts";
export { extractExceptionChain, isInAppFilename, parseStackFrames, parseStackLine } from "./stacktrace.ts";
export { createBrowserTransport } from "./transport.ts";
export {
  BrowserClient,
  addBreadcrumb,
  captureEvent,
  captureException,
  captureMessage,
  clearBreadcrumbs,
  close,
  flush,
  getClient,
  getConfig,
  getCurrentScope,
  getGlobalScope,
  getIsolationScope,
  init,
  initRails,
  isEnabled,
  isInitialized,
  lastEventId,
  registerStimulusErrorHandler,
  resetClient,
  setContext,
  setExtra,
  setExtras,
  setTag,
  setTags,
  setUser,
  withScope
} from "./client.ts";
export type {
  Breadcrumb,
  BrowserOptions,
  CaptureContext,
  ParsedDsn,
  RailsMetaConfig,
  ScopeContext,
  ScopeLike,
  SentryEvent,
  SentryEventHint,
  SentryExceptionValue,
  SentryRequestInfo,
  SentraceOptions,
  SeverityLevel,
  StackFrame,
  StimulusApplicationLike,
  StimulusErrorDetail,
  Transport,
  TransportMakeRequestResponse,
  User
} from "./types.ts";

import {
  BrowserClient,
  addBreadcrumb,
  captureEvent,
  captureException,
  captureMessage,
  clearBreadcrumbs,
  close,
  flush,
  getClient,
  getConfig,
  getCurrentScope,
  getGlobalScope,
  getIsolationScope,
  init,
  initRails,
  isEnabled,
  isInitialized,
  lastEventId,
  registerStimulusErrorHandler,
  resetClient,
  setContext,
  setExtra,
  setExtras,
  setTag,
  setTags,
  setUser,
  withScope
} from "./client.ts";
import { SDK_CLIENT, SDK_NAME, VERSION, buildEnvelopeEndpoint, parseDsn, scrubUrl } from "./dsn.ts";
import { serializeEnvelope } from "./envelope.ts";
import { readRailsMeta } from "./rails.ts";
import { Scope } from "./scope.ts";
import { parseStackFrames } from "./stacktrace.ts";

const Sentrace = {
  VERSION,
  SDK_NAME,
  SDK_CLIENT,
  BrowserClient,
  Scope,
  init,
  initRails,
  getConfig,
  getClient,
  isInitialized,
  isEnabled,
  lastEventId,
  getCurrentScope,
  getGlobalScope,
  getIsolationScope,
  withScope,
  captureException,
  captureMessage,
  captureEvent,
  addBreadcrumb,
  clearBreadcrumbs,
  setTag,
  setTags,
  setUser,
  setContext,
  setExtra,
  setExtras,
  flush,
  close,
  resetClient,
  readRailsMeta,
  registerStimulusErrorHandler,
  parseDsn,
  buildEnvelopeEndpoint,
  scrubUrl,
  parseStackFrames,
  serializeEnvelope
};

export default Sentrace;
