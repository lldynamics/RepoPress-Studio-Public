import { act, createElement, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RssGateway, RssPreferences } from "../features/rss/contracts";
import { I18nProvider } from "../i18n/i18n";
import { RssReader } from "./RssReader";

vi.mock("../features/translation/RssTranslationPanel", () => ({ RssTranslationPanel: () => null }));
vi.mock("../features/translation/RssBatchTranslationDialog", () => ({ RssBatchTranslationDialog: () => null }));
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

const preferences: RssPreferences = { automaticPruningEnabled: false, retentionDays: 90, feedBodyOfflineCacheEnabled: false, privateNetworkAccessEnabled: false, backgroundRefreshEnabled: true, backgroundRefreshIntervalMinutes: 15, automaticMarkReadAtEndEnabled: true, automaticFullTextExtractionEnabled: false, offlineCacheFullTextOnRefreshEnabled: false, remoteImagesEnabled: false, offlineTranslationCacheEnabled: false, offlineTranslationRetentionDays: 30, offlineTranslationMaxMiB: 100, automaticLocalPretranslationOnRefreshEnabled: false };
const feed = { id: "feed", title: "Demo", url: "https://example.test/feed", siteUrl: null, iconUrl: null, addedAt: 1, lastUpdatedAt: null, etag: null, lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: null, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: null };
const snapshot = { feeds: [feed], articles: [], articleCount: 0, unreadCount: 0, starredCount: 0, unreadCountByFeed: {}, authors: [], tags: [], statusMessage: null, errorMessage: null };
const page = { articles: [], totalCount: 0, hasMore: false };

function makeGateway(overrides: Partial<RssGateway> = {}) {
  return {
    snapshot: vi.fn(async () => snapshot), getPreferences: vi.fn(async () => preferences), listArticles: vi.fn(async () => page),
    refreshAll: vi.fn(async () => ({ successCount: 0, failureCount: 0, skippedCount: 0 })), refreshFeed: vi.fn(async () => ({ successCount: 0, failureCount: 0, skippedCount: 0 })),
    ...overrides,
  } as unknown as RssGateway;
}

let host: HTMLDivElement; let root: Root;
function render(gateway: RssGateway, active = true, locale: "en-US" | "zh-CN" = "en-US") { act(() => root.render(createElement(I18nProvider, { locale, children: createElement(RssReader, { gateway, active }) }))); }
async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }

beforeEach(() => { vi.useFakeTimers(); host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe("RSS automatic refresh lifecycle", () => {
  it("waits for preferences, then refreshes on the configured interval", async () => {
    let resolvePreferences!: (value: RssPreferences) => void;
    const pendingPreferences = new Promise<RssPreferences>((resolve) => { resolvePreferences = resolve; });
    const gateway = makeGateway({ getPreferences: vi.fn(() => pendingPreferences) });
    render(gateway); await act(async () => { await Promise.resolve(); });
    await vi.advanceTimersByTimeAsync(15 * 60_000);
    expect(gateway.refreshAll).not.toHaveBeenCalled();

    resolvePreferences(preferences); await settle();
    await vi.advanceTimersByTimeAsync(15 * 60_000);
    expect(gateway.refreshAll).toHaveBeenCalledWith(false);
  });

  it("does not overlap a pending refresh across remounts sharing a gateway", async () => {
    let resolveRefresh!: (value: { successCount: number; failureCount: number; skippedCount: number }) => void;
    const pending = new Promise<{ successCount: number; failureCount: number; skippedCount: number }>((resolve) => { resolveRefresh = resolve; });
    const gateway = makeGateway({ refreshAll: vi.fn(() => pending) });
    render(gateway); await settle(); await vi.advanceTimersByTimeAsync(15 * 60_000);
    act(() => root.unmount());
    root = createRoot(host); render(gateway); await settle(); await vi.advanceTimersByTimeAsync(15 * 60_000);
    expect(gateway.refreshAll).toHaveBeenCalledTimes(1);
    resolveRefresh({ successCount: 0, failureCount: 0, skippedCount: 0 }); await settle();
  });

  it("uses force=true for both manual all-feed and feed refresh", async () => {
    const gateway = makeGateway(); render(gateway); await settle();
    const all = [...host.querySelectorAll<HTMLButtonElement>(".rss-sidebar-actions button")].find((button) => button.textContent === "Refresh all")!;
    await act(async () => { all.click(); }); await settle();
    expect(gateway.refreshAll).toHaveBeenCalledWith(true);
    const feedRefresh = host.querySelector<HTMLButtonElement>('button[aria-label="Refresh Demo"]')!;
    await act(async () => { feedRefresh.click(); }); await settle();
    expect(gateway.refreshFeed).toHaveBeenCalledWith("feed", true);
  });

  it("does not overlap manual and automatic refresh, and retries after rejection", async () => {
    let resolveRefresh!: (value: { successCount: number; failureCount: number; skippedCount: number }) => void;
    const pending = new Promise<{ successCount: number; failureCount: number; skippedCount: number }>((resolve) => { resolveRefresh = resolve; });
    const refreshAll = vi.fn().mockRejectedValueOnce(new Error("temporary")).mockResolvedValue({ successCount: 0, failureCount: 0, skippedCount: 0 });
    const gateway = makeGateway({ refreshAll }); render(gateway); await settle();
    await act(async () => { host.querySelector<HTMLButtonElement>('.rss-sidebar-actions button')!.click(); });
    await settle();
    expect(refreshAll).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(15 * 60_000);
    expect(refreshAll).toHaveBeenCalledTimes(2);
    const slowGateway = makeGateway({ refreshAll: vi.fn(() => pending) }); render(slowGateway); await settle();
    await act(async () => { host.querySelector<HTMLButtonElement>('.rss-sidebar-actions button')!.click(); });
    await vi.advanceTimersByTimeAsync(15 * 60_000);
    expect(slowGateway.refreshAll).toHaveBeenCalledTimes(1);
    resolveRefresh({ successCount: 0, failureCount: 0, skippedCount: 0 }); await settle();
  });

  it("does not auto-refresh when disabled or when preference loading fails", async () => {
    const disabled = makeGateway({ getPreferences: vi.fn(async () => ({ ...preferences, backgroundRefreshEnabled: false })) });
    render(disabled); await settle(); await vi.advanceTimersByTimeAsync(60 * 60_000); expect(disabled.refreshAll).not.toHaveBeenCalled();
    const failed = makeGateway({ getPreferences: vi.fn(async () => { throw new Error("preferences unavailable"); }) });
    render(failed); await settle(); await vi.advanceTimersByTimeAsync(60 * 60_000); expect(failed.refreshAll).not.toHaveBeenCalled();
  });

  it("keeps the interval through filter and language rerenders", async () => {
    const gateway = makeGateway(); render(gateway); await settle();
    await vi.advanceTimersByTimeAsync(15 * 60_000 / 2);
    const search = host.querySelector<HTMLInputElement>('.rss-filters input')!;
    await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "needle"); search.dispatchEvent(new Event("input", { bubbles: true })); });
    render(gateway, true, "zh-CN"); await settle();
    await vi.advanceTimersByTimeAsync(15 * 60_000 / 2 - 1); expect(gateway.refreshAll).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1); expect(gateway.refreshAll).toHaveBeenCalledWith(false);
  });

  it("ignores a pending refresh after active changes and does not reload or publish stale status", async () => {
    let resolveRefresh!: (value: { successCount: number; failureCount: number; skippedCount: number; statusText?: string }) => void;
    const pending = new Promise<{ successCount: number; failureCount: number; skippedCount: number; statusText?: string }>((resolve) => { resolveRefresh = resolve; });
    const gateway = makeGateway({ refreshAll: vi.fn(() => pending) }); render(gateway); await settle(); await vi.advanceTimersByTimeAsync(15 * 60_000);
    render(gateway, false); render(gateway, true); await settle();
    const snapshots = vi.mocked(gateway.snapshot).mock.calls.length; const lists = vi.mocked(gateway.listArticles).mock.calls.length;
    expect(host.querySelector<HTMLButtonElement>('.rss-sidebar-actions button')?.disabled).toBe(true);
    resolveRefresh({ successCount: 1, failureCount: 0, skippedCount: 0, statusText: "stale" }); await settle();
    expect(gateway.snapshot).toHaveBeenCalledTimes(snapshots); expect(gateway.listArticles).toHaveBeenCalledTimes(lists); expect(host.textContent).not.toContain("stale");
    expect(host.querySelector<HTMLButtonElement>('.rss-sidebar-actions button')?.disabled).toBe(false);
  });

  it("does not show a preference error from an older A to B to A lifecycle", async () => {
    let rejectPreferences!: (reason: unknown) => void;
    const pending = new Promise<RssPreferences>((_resolve, reject) => { rejectPreferences = reject; });
    const gatewayA = makeGateway({ getPreferences: vi.fn().mockImplementationOnce(() => pending).mockResolvedValue(preferences) });
    const gatewayB = makeGateway();
    render(gatewayA); await act(async () => { await Promise.resolve(); });
    render(gatewayB); await settle(); render(gatewayA); await settle();
    rejectPreferences(new Error("stale preferences")); await settle();
    expect(host.querySelector('[role="alert"]')).toBeNull();
  });

  it("stops scheduling when inactive", async () => {
    const gateway = makeGateway(); render(gateway); await settle();
    render(gateway, false); await vi.advanceTimersByTimeAsync(15 * 60_000); expect(gateway.refreshAll).not.toHaveBeenCalled();
  });

  it("reloads the current search when a slow refresh completes", async () => {
    let resolveRefresh!: (value: { successCount: number; failureCount: number; skippedCount: number }) => void;
    const pending = new Promise<{ successCount: number; failureCount: number; skippedCount: number }>((resolve) => { resolveRefresh = resolve; });
    const gateway = makeGateway({ refreshAll: vi.fn(() => pending) });
    render(gateway); await settle();
    await act(async () => { await vi.advanceTimersByTimeAsync(15 * 60_000); });
    const search = host.querySelector<HTMLInputElement>(".rss-filters input")!;
    await act(async () => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "latest query");
      search.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await settle();
    expect(vi.mocked(gateway.listArticles).mock.lastCall?.[0].searchText).toBe("latest query");
    await act(async () => { resolveRefresh({ successCount: 1, failureCount: 0, skippedCount: 0 }); });
    await settle();
    expect(vi.mocked(gateway.listArticles).mock.lastCall?.[0].searchText).toBe("latest query");
  });

  it("ignores the first preference failure during StrictMode effect replay", async () => {
    let rejectOld!: (error: Error) => void;
    const old = new Promise<RssPreferences>((_resolve, reject) => { rejectOld = reject; });
    const gateway = makeGateway({ getPreferences: vi.fn().mockReturnValueOnce(old).mockResolvedValue(preferences) });
    act(() => root.render(createElement(StrictMode, { children: createElement(I18nProvider, { locale: "en-US", children: createElement(RssReader, { gateway, active: true }) }) })));
    await settle();
    await act(async () => { rejectOld(new Error("stale StrictMode preferences")); });
    await settle();
    expect(host.textContent).not.toContain("stale StrictMode preferences");
    await act(async () => { await vi.advanceTimersByTimeAsync(15 * 60_000); });
    expect(gateway.refreshAll).toHaveBeenCalledWith(false);
  });

  it("does not start future refreshes after unmount", async () => {
    const gateway = makeGateway(); render(gateway); await settle();
    act(() => root.unmount()); root = createRoot(host);
    await act(async () => { await vi.advanceTimersByTimeAsync(60 * 60_000); });
    expect(gateway.refreshAll).not.toHaveBeenCalled();
  });
});
