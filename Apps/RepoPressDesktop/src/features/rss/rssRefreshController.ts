import type { RssGateway } from "./contracts";

// Keep refreshes exclusive across remounts that share a gateway instance.
const inFlight = new WeakMap<object, Promise<unknown>>();
type RefreshRecord = { busy: boolean; listeners: Set<() => void> };
const records = new WeakMap<object, RefreshRecord>();

function recordFor(gateway: RssGateway): RefreshRecord {
  let record = records.get(gateway);
  if (!record) { record = { busy: false, listeners: new Set() }; records.set(gateway, record); }
  return record;
}

export function isRssRefreshBusy(gateway: RssGateway): boolean { return recordFor(gateway).busy; }
export function subscribeRssRefresh(gateway: RssGateway, listener: () => void): () => void {
  const record = recordFor(gateway); record.listeners.add(listener);
  return () => record.listeners.delete(listener);
}

function setBusy(gateway: RssGateway, busy: boolean) {
  const record = recordFor(gateway); record.busy = busy;
  for (const listener of record.listeners) listener();
}

export async function runRssRefreshExclusive<T>(gateway: RssGateway, operation: () => Promise<T>): Promise<T | undefined> {
  if (inFlight.has(gateway)) return undefined;
  // Install the latch before invoking user code so synchronous throws cannot race
  // another refresh call in the same turn.
  const latch = Promise.resolve();
  inFlight.set(gateway, latch);
  setBusy(gateway, true);
  try {
    return await operation();
  } finally {
    if (inFlight.get(gateway) === latch) inFlight.delete(gateway);
    setBusy(gateway, false);
  }
}
