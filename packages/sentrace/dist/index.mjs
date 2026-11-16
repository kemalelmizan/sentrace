export const VERSION = "0.0.1";

let currentConfig = null;

/**
 * Initialize the Sentrace frontend SDK (0.0.1 placeholder stub).
 * @param {import("./index.d.ts").SentraceOptions} [options]
 */
export function init(options = {}) {
  currentConfig = Object.freeze({
    enabled: options.enabled ?? true,
    dsn: options.dsn ?? null,
    environment: options.environment ?? "production",
    release: options.release ?? null
  });
  return currentConfig;
}

export function getConfig() {
  return currentConfig;
}

export function captureException(_error, _context = {}) {
  return null;
}

export function captureMessage(_message, _level = "error", _context = {}) {
  return null;
}

export function addBreadcrumb(_breadcrumb) {
  // No-op in 0.0.1 stub release
}

export function resetClient() {
  currentConfig = null;
}

export default {
  VERSION,
  init,
  getConfig,
  captureException,
  captureMessage,
  addBreadcrumb,
  resetClient
};
