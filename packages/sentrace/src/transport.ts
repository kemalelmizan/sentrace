import type { Transport, TransportMakeRequestResponse } from "./types.ts";

export const SENTRACE_INTERNAL_FETCH_FLAG = "__sentraceInternalRequest";

export function createBrowserTransport(endpointUrl: string): Transport {
  const pending = new Set<Promise<unknown>>();

  const sendViaBeacon = (envelope: string): boolean => {
    try {
      const nav = (globalThis as { navigator?: { sendBeacon?: (url: string, data: BodyInit) => boolean } }).navigator;
      if (nav && typeof nav.sendBeacon === "function") {
        return nav.sendBeacon(endpointUrl, envelope);
      }
    } catch {
      // Ignore sendBeacon errors
    }
    return false;
  };

  const send = (envelope: string): Promise<TransportMakeRequestResponse> => {
    const doc = (globalThis as { document?: { visibilityState?: string } }).document;
    if (doc?.visibilityState === "hidden" && sendViaBeacon(envelope)) {
      return Promise.resolve({ statusCode: 200 });
    }

    const fetchFn = (globalThis as { fetch?: typeof fetch }).fetch;
    if (typeof fetchFn !== "function") {
      const ok = sendViaBeacon(envelope);
      return Promise.resolve({ statusCode: ok ? 200 : 0 });
    }

    const initOptions: RequestInit & { [SENTRACE_INTERNAL_FETCH_FLAG]?: boolean } = {
      method: "POST",
      body: envelope,
      headers: {
        "Content-Type": "text/plain;charset=UTF-8"
      },
      keepalive: true,
      credentials: "omit"
    };
    Object.defineProperty(initOptions, SENTRACE_INTERNAL_FETCH_FLAG, {
      value: true,
      enumerable: false
    });

    const requestPromise = fetchFn(endpointUrl, initOptions)
      .then((res) => ({ statusCode: res.status }))
      .catch(() => {
        const fallbackOk = sendViaBeacon(envelope);
        return { statusCode: fallbackOk ? 200 : 0 };
      });

    pending.add(requestPromise);
    void requestPromise.finally(() => {
      pending.delete(requestPromise);
    });

    return requestPromise;
  };

  const flush = async (timeout = 2000): Promise<boolean> => {
    if (pending.size === 0) {
      return true;
    }

    const allDone = Promise.allSettled(Array.from(pending)).then(() => true);
    if (timeout <= 0) {
      return allDone;
    }

    let timer: ReturnType<typeof setTimeout> | undefined;
    const timedOut = new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), timeout);
    });

    const result = await Promise.race([allDone, timedOut]);
    if (timer !== undefined) {
      clearTimeout(timer);
    }
    return result;
  };

  return {
    send,
    sendOnExit: sendViaBeacon,
    flush
  };
}
