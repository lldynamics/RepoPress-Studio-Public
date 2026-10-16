import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RssFeed, RssGateway, RssHistoryCheckpointSummary } from "../features/rss/contracts";
import { I18nProvider } from "../i18n/i18n";
import { RssHistoryQueueDialog } from "./RssHistoryQueueDialog";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const feed: RssFeed = { id: "feed", title: "Feed", url: "https://example.com/feed.xml", siteUrl: "https://example.com/", iconUrl: null, addedAt: 1, lastUpdatedAt: null, etag: null, lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: null, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: null };
const summary: RssHistoryCheckpointSummary = { id: "job", feedId: feed.id, directoryUrl: "https://example.com/archive/", status: "paused", candidateCount: 5, pendingCount: 2, addedCount: 1, duplicateCount: 1, updatedCount: 0, failedCount: 1, discoveredCount: 12, hasMoreDiscovery: true, stale: false };
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }
function gateway(overrides: Partial<RssGateway> = {}) { return { historyList: vi.fn(async () => [summary]), historyClear: vi.fn(async () => undefined), ...overrides } as unknown as RssGateway; }

let host: HTMLDivElement; let root: Root;
const settle = () => act(async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); });
function button(label: string) { const target = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label || item.getAttribute("aria-label") === label); if (!target) throw new Error(`Missing button ${label}`); return target; }
function render(rssGateway: RssGateway, feeds = [feed], onClose = vi.fn(), onOpen = vi.fn(), locale: "zh-CN" | "en-US" = "zh-CN") { act(() => root.render(<I18nProvider locale={locale}><RssHistoryQueueDialog gateway={rssGateway} feeds={feeds} onClose={onClose} onOpen={onOpen} /></I18nProvider>)); return { onClose, onOpen }; }

beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); });

describe("RSS history checkpoint queue", () => {
  it("lists at most twenty saved summaries without resuming discovery", async () => {
    const many = Array.from({ length: 24 }, (_, index) => ({ ...summary, id: `job-${index}`, directoryUrl: `https://example.com/archive/${index}/` }));
    const rssGateway = gateway({ historyList: vi.fn(async () => many), historyResumeDiscovery: vi.fn() }); render(rssGateway); await settle();
    expect(host.querySelectorAll(".rss-history-queue-list > li")).toHaveLength(20);
    expect(rssGateway.historyList).toHaveBeenCalledTimes(1); expect(rssGateway.historyResumeDiscovery).not.toHaveBeenCalled();
    expect(host.textContent).toContain("本段候选 5"); expect(host.textContent).toContain("本段待处理 2"); expect(host.textContent).toContain("全量未解决失败 1");
  });

  it("labels a persisted failed-retry batch and its all-job failure count in English", async () => {
    const retrying = { ...summary, retryingFailures: true, candidateCount: 3, pendingCount: 3, failedCount: 17 };
    render(gateway({ historyList: vi.fn(async () => [retrying]) }), [feed], vi.fn(), vi.fn(), "en-US"); await settle();
    expect(host.textContent).toContain("Failed retry batch"); expect(host.textContent).toContain("candidates in this batch 3"); expect(host.textContent).toContain("unresolved failures across the job 17");
  });

  it("keeps stale checkpoints visible and disables unsafe row actions", async () => {
    const stale = { ...summary, id: "stale", feedId: "missing", stale: true };
    const running = { ...summary, id: "running", status: "running" as const };
    const rssGateway = gateway({ historyList: vi.fn(async () => [stale, running]) }); render(rssGateway); await settle();
    expect(host.textContent).toContain("失效检查点"); expect(host.textContent).toContain("订阅已不存在");
    const rows = host.querySelectorAll<HTMLLIElement>(".rss-history-queue-list > li");
    expect(rows[0].querySelectorAll<HTMLButtonElement>("button")[0].disabled).toBe(true);
    expect(rows[1].querySelectorAll<HTMLButtonElement>("button")[1].disabled).toBe(true);
    expect(rssGateway.historyClear).not.toHaveBeenCalled();
  });

  it("requires row confirmation, clears only the checkpoint, and refreshes the list", async () => {
    const confirm = vi.spyOn(window, "confirm").mockReturnValueOnce(false).mockReturnValueOnce(true);
    const rssGateway = gateway({ historyList: vi.fn().mockResolvedValueOnce([summary]).mockResolvedValueOnce([]) }); render(rssGateway); await settle();
    await act(async () => button("清除检查点").click()); expect(rssGateway.historyClear).not.toHaveBeenCalled();
    await act(async () => button("清除检查点").click()); await settle();
    expect(confirm.mock.calls[1][0]).toContain("已保存文章、全文缓存和阅读状态会保留");
    expect(confirm.mock.calls[1][0]).toContain("清除后不能从原位置继续发现");
    expect(rssGateway.historyClear).toHaveBeenCalledWith("job"); expect(rssGateway.historyList).toHaveBeenCalledTimes(2);
    expect(host.textContent).toContain("文章、缓存和阅读状态未更改"); expect(host.textContent).toContain("没有保存的历史补全检查点");
  });

  it("discloses in English that clearing loses the saved discovery position", async () => {
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false); render(gateway(), [feed], vi.fn(), vi.fn(), "en-US"); await settle();
    await act(async () => button("Clear checkpoint").click());
    expect(confirm).toHaveBeenCalledWith(expect.stringContaining("cannot continue discovery from the previous position"));
    expect(confirm.mock.calls[0][0]).toContain("full-text cache, and reading state will be preserved");
  });

  it("ignores a stale list result after close and restores focus on Escape", async () => {
    const pending = deferred<RssHistoryCheckpointSummary[]>(); const rssGateway = gateway({ historyList: vi.fn(() => pending.promise) });
    const previous = document.createElement("button"); document.body.append(previous); previous.focus();
    const { onClose } = render(rssGateway); await settle();
    await act(async () => window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    expect(onClose).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve([summary])); await settle();
    expect(host.textContent).not.toContain(summary.directoryUrl);
    act(() => root.render(null)); expect(document.activeElement).toBe(previous); previous.remove();
  });

  it("shows a bounded structured corrective error without dropping the saved row", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true);
    const rssGateway = gateway({ historyClear: vi.fn(async () => Promise.reject({ code: "RUNNING", message: `请先暂停当前任务。${"x".repeat(600)}` })) }); render(rssGateway); await settle();
    await act(async () => button("清除检查点").click()); await settle();
    expect(host.querySelector('[role="alert"]')?.textContent).toHaveLength(500); expect(host.textContent).toContain(summary.directoryUrl);
  });
});
