"use strict";

const VERSION = "0.0.1";

let currentConfig = null;

function init(options = {}) {
  currentConfig = Object.freeze({
    enabled: options.enabled ?? true,
    dsn: options.dsn ?? null,
    environment: options.environment ?? "production",
    release: options.release ?? null
  });
  return currentConfig;
}

function getConfig() {
  return currentConfig;
}

function captureException(_error, _context = {}) {
  return null;
}

function captureMessage(_message, _level = "error", _context = {}) {
  return null;
}

function addBreadcrumb(_breadcrumb) {
  // No-op in 0.0.1 stub release
}

function resetClient() {
  currentConfig = null;
}

module.exports = {
  VERSION,
  init,
  getConfig,
  captureException,
  captureMessage,
  addBreadcrumb,
  resetClient
};
