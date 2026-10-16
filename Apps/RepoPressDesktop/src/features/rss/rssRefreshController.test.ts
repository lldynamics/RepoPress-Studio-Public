import { describe, expect, it, vi } from "vitest";
import type { RssGateway } from "./contracts";
import { isRssRefreshBusy, runRssRefreshExclusive, subscribeRssRefresh } from "./rssRefreshController";

describe("gateway refresh exclusivity", () => {
  it("claims before synchronous reentry and releases after a synchronous throw", async () => {
    const gateway = {} as RssGateway;
    const nested = vi.fn(async () => undefined);
    const observed: boolean[] = [];
    const unsubscribe = subscribeRssRefresh(gateway, () => observed.push(isRssRefreshBusy(gateway)));
    await expect(runRssRefreshExclusive(gateway, () => {
      expect(isRssRefreshBusy(gateway)).toBe(true);
      void runRssRefreshExclusive(gateway, nested);
      throw new Error("synchronous transport failure");
    })).rejects.toThrow("synchronous transport failure");
    expect(nested).not.toHaveBeenCalled();
    expect(observed).toEqual([true, false]);
    expect(isRssRefreshBusy(gateway)).toBe(false);
    await runRssRefreshExclusive(gateway, nested);
    expect(nested).toHaveBeenCalledTimes(1);
    unsubscribe();
  });
});
