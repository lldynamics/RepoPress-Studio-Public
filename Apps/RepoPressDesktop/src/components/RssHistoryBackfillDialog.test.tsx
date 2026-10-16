import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RssFeed, RssGateway, RssHistoryJob } from "../features/rss/contracts";
import { I18nProvider } from "../i18n/i18n";
import { RssHistoryBackfillDialog } from "./RssHistoryBackfillDialog";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const feed: RssFeed = { id: "feed", title: "Feed", url: "https://example.com/feed.xml", siteUrl: "https://www.example.com/", iconUrl: null, addedAt: 1, lastUpdatedAt: null, etag: null, lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: null, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: null };
const candidates = [{ url: "https://www.example.com/posts/one", title: "One", status: "pending" as const, message: null }, { url: "https://www.example.com/posts/two", title: "Two", status: "pending" as const, message: null }];
const preview: RssHistoryJob = { id: "job", feedId: feed.id, directoryUrl: "https://www.example.com/archive/", status: "preview", candidates, addedCount: 0, duplicateCount: 0, failedCount: 0, nextRequestAt: 0, reachedLimit: false, message: null };
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }
function gateway(overrides: Partial<RssGateway> = {}) { return { historyStatus: vi.fn(async () => null), historyDiscover: vi.fn(async () => preview), historyResumeDiscovery: vi.fn(async () => preview), historyCancelDiscovery: vi.fn(async () => undefined), historyPrepareRetry: vi.fn(async () => preview), historyStep: vi.fn(async () => ({ ...preview, status: "complete" as const, candidates: candidates.map((item) => ({ ...item, status: "added" as const })), addedCount: 2 })), historyPause: vi.fn(async () => ({ ...preview, status: "paused" as const })), ...overrides } as unknown as RssGateway; }
let host: HTMLDivElement; let root: Root;
const settle = () => act(async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); });
function button(label: string) { const value = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label); if (!value) throw new Error(`Missing button: ${label}`); return value; }
async function click(label: string) { await act(async () => button(label).click()); await settle(); }
async function setNumberInput(label: string, value: number) { const input = [...host.querySelectorAll<HTMLInputElement>('input[type="number"]')].find((item) => item.closest("label")?.textContent?.includes(label)); if (!input) throw new Error(`Missing number input: ${label}`); await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, String(value)); input.dispatchEvent(new Event("input", { bubbles: true })); }); }
function render(rssGateway: RssGateway, onChanged = vi.fn(), onClose = vi.fn(), locale: "zh-CN" | "en-US" = "zh-CN") { act(() => root.render(<I18nProvider locale={locale}><RssHistoryBackfillDialog feed={feed} gateway={rssGateway} onChanged={onChanged} onClose={onClose} /></I18nProvider>)); return { onChanged, onClose }; }

beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); vi.useFakeTimers(); vi.setSystemTime(new Date("2026-10-12T00:00:00Z")); });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe("RSS history backfill", () => {
  it("discovers a preview without inserting and requires the write confirmation", async () => {
    const rssGateway = gateway(); render(rssGateway); await settle(); await click("发现候选文章");
    expect(rssGateway.historyDiscover).toHaveBeenCalledWith({ feedId: "feed", directoryUrl: "https://www.example.com/", maxPages: 10, maxArticles: 100, discoveryId: expect.any(String), fillExisting: false });
    expect(rssGateway.historyStep).not.toHaveBeenCalled(); expect(button("开始补全").disabled).toBe(true); expect(host.textContent).toContain("本段候选文章（2）"); expect(host.textContent).toContain("已审查来源：https://www.example.com/archive/");
    await act(async () => host.querySelector<HTMLInputElement>(".rss-history-confirm input")!.click()); expect(button("开始补全").disabled).toBe(false);
    const directory = host.querySelector<HTMLInputElement>('input[placeholder="https://example.com/archive/"]')!;
    await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(directory, "https://www.example.com/older/"); directory.dispatchEvent(new Event("input", { bubbles: true })); });
    expect(host.textContent).not.toContain("本段候选文章（2）"); expect(host.textContent).not.toContain("开始补全");
  });

  it("opts in explicitly before discovering existing-article full text", async () => {
    const fullTextPreview: RssHistoryJob = { ...preview, candidates: [{ ...candidates[0], kind: "fullText", status: "updated" }], updatedCount: 1, discoveredCount: 7, fillExisting: true };
    const rssGateway = gateway({ historyDiscover: vi.fn(async () => fullTextPreview) }); render(rssGateway); await settle();
    const optIn = host.querySelector<HTMLInputElement>(".rss-history-fill-existing input")!;
    expect(optIn.checked).toBe(false);
    expect(host.querySelector(".rss-history-fill-existing")?.textContent).toContain("缺失或仅含摘要、截断内容的正文"); expect(host.querySelector(".rss-history-fill-existing")?.textContent).toContain("写入本机全文缓存"); expect(host.querySelector(".rss-history-fill-existing")?.textContent).toContain("原文和阅读状态不变");
    expect(host.textContent).toContain("已就绪的本机全文缓存会优先复用；短但完整的文章不会仅因篇幅短而请求。");
    render(rssGateway, vi.fn(), vi.fn(), "en-US"); await settle();
    expect(host.querySelector(".rss-history-fill-existing")?.textContent).toContain("body of existing articles when it is missing, contains only a summary, or is truncated");
    expect(host.textContent).toContain("Ready local full-text cache is reused first. A short but complete article is not requested just because it is short.");
    render(rssGateway); await settle();
    await act(async () => host.querySelector<HTMLInputElement>(".rss-history-fill-existing input")!.click());
    await click("发现候选文章");
    expect(rssGateway.historyDiscover).toHaveBeenCalledWith(expect.objectContaining({ fillExisting: true }));
    expect(host.textContent).toContain("已有文章全文"); expect(host.textContent).toContain("已补全文 1"); expect(host.textContent).toContain("累计发现 7");
  });

  it("recovers the last persisted checkpoint read-only after discovery fails", async () => {
    const persisted: RssHistoryJob = { ...preview, candidates: [{ ...candidates[0], status: "pending" }], discoveredCount: 1, hasMoreDiscovery: true };
    const rssGateway = gateway({ historyStatus: vi.fn().mockResolvedValueOnce(null).mockResolvedValueOnce(persisted), historyDiscover: vi.fn(async () => Promise.reject({ code: "DISCOVERY_FAILED", message: "发现中断；已保存部分进度。" })) });
    render(rssGateway); await settle(); await click("发现候选文章");
    expect(rssGateway.historyStatus).toHaveBeenCalledTimes(2); expect(host.textContent).toContain("本段候选文章（1）"); expect(host.querySelector('[role="alert"]')?.textContent).toContain("已保存部分进度");
    expect(rssGateway.historyResumeDiscovery).not.toHaveBeenCalled(); expect(rssGateway.historyStep).not.toHaveBeenCalled();
  });

  it("never auto-resumes discovery and waits for the saved deadline after an explicit click", async () => {
    const resumable: RssHistoryJob = { ...preview, status: "complete", candidates: candidates.map((item) => ({ ...item, status: "added" as const })), addedCount: 2, hasMoreDiscovery: true, discoveredCount: 100, nextRequestAt: Math.floor(Date.now() / 1000) + 1 };
    const resumed = { ...resumable, candidates: [...resumable.candidates, { url: "https://www.example.com/posts/three", title: "Three", status: "pending" as const, message: null }], discoveredCount: 101 };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => resumable), historyResumeDiscovery: vi.fn(async () => resumed) }); render(rssGateway); await settle();
    expect(rssGateway.historyResumeDiscovery).not.toHaveBeenCalled();
    await click("继续发现历史链接"); expect(rssGateway.historyResumeDiscovery).not.toHaveBeenCalled();
    await act(async () => { vi.advanceTimersByTime(999); await Promise.resolve(); }); expect(rssGateway.historyResumeDiscovery).not.toHaveBeenCalled();
    await act(async () => { vi.advanceTimersByTime(1); await Promise.resolve(); await Promise.resolve(); });
    expect(rssGateway.historyResumeDiscovery).toHaveBeenCalledWith({ jobId: "job", discoveryId: expect.any(String), maxPages: 10, maxArticles: 100 });
  });

  it("cancels an explicit resume that is waiting for its deadline", async () => {
    const resumable: RssHistoryJob = { ...preview, status: "complete", candidates: candidates.map((item) => ({ ...item, status: "duplicate" as const })), duplicateCount: 2, hasMoreDiscovery: true, nextRequestAt: Math.floor(Date.now() / 1000) + 10 };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => resumable) }); const { onClose } = render(rssGateway); await settle();
    await click("继续发现历史链接");
    const discoveryId = vi.mocked(rssGateway.historyCancelDiscovery).mock.calls.length;
    expect(rssGateway.historyResumeDiscovery).not.toHaveBeenCalled();
    await act(async () => host.querySelector<HTMLButtonElement>('.rss-history-backfill header button')!.click());
    expect(onClose).toHaveBeenCalledTimes(1); expect(rssGateway.historyCancelDiscovery).toHaveBeenCalledTimes(discoveryId + 1);
    vi.advanceTimersByTime(10_000); await settle(); expect(rssGateway.historyResumeDiscovery).not.toHaveBeenCalled();
  });

  it("waits for the saved deadline before the first resume request", async () => {
    const delayed = { ...preview, status: "paused" as const, nextRequestAt: Math.floor(Date.now() / 1000) + 1 };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => delayed) }); render(rssGateway); await settle();
    await act(async () => host.querySelector<HTMLInputElement>(".rss-history-confirm input")!.click()); await click("继续补全");
    expect(rssGateway.historyStep).not.toHaveBeenCalled();
    await act(async () => { vi.advanceTimersByTime(999); await Promise.resolve(); }); expect(rssGateway.historyStep).not.toHaveBeenCalled();
    await act(async () => { vi.advanceTimersByTime(1); await Promise.resolve(); await Promise.resolve(); }); expect(rssGateway.historyStep).toHaveBeenCalledTimes(1);
  });

  it("runs sequential steps, honors nextRequestAt, pauses, and resumes manually", async () => {
    const running: RssHistoryJob = { ...preview, status: "running", candidates: [{ ...candidates[0], status: "added" }, candidates[1]], addedCount: 1, nextRequestAt: Math.floor(Date.now() / 1000) + 1 };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => ({ ...preview, status: "paused" as const })), historyStep: vi.fn().mockResolvedValueOnce(running).mockResolvedValueOnce({ ...running, status: "complete", candidates: candidates.map((item) => ({ ...item, status: "added" as const })), addedCount: 2 }), historyPause: vi.fn(async () => ({ ...running, status: "paused" as const })) });
    const { onChanged } = render(rssGateway); await settle(); await act(async () => host.querySelector<HTMLInputElement>(".rss-history-confirm input")!.click()); await click("继续补全");
    expect(rssGateway.historyStep).toHaveBeenCalledTimes(1); expect(onChanged).toHaveBeenCalledTimes(1);
    await click("暂停补全"); expect(rssGateway.historyPause).toHaveBeenCalledWith("job");
    await act(async () => { vi.advanceTimersByTime(1000); await Promise.resolve(); }); expect(rssGateway.historyStep).toHaveBeenCalledTimes(1);
    await click("继续补全");
    expect(rssGateway.historyStep).toHaveBeenCalledTimes(2); expect(onChanged).toHaveBeenCalledTimes(2);
  });

  it("previews failed retries locally and requires fresh confirmation before an ordinary step", async () => {
    const failed: RssHistoryJob = { ...preview, status: "paused", candidates: [{ ...candidates[0], status: "failed", message: "failed" }], failedCount: 1 };
    const retryPreview: RssHistoryJob = { ...failed, status: "preview", candidates: [{ ...candidates[0], status: "pending", message: null }], retryingFailures: true };
    const completedRetry: RssHistoryJob = { ...retryPreview, status: "complete", candidates: [{ ...candidates[0], status: "added", message: null }], failedCount: 0, addedCount: 1 };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => failed), historyPrepareRetry: vi.fn(async () => retryPreview), historyStep: vi.fn(async () => completedRetry) });
    render(rssGateway); await settle(); await click("预览失败重试");
    expect(rssGateway.historyPrepareRetry).toHaveBeenCalledWith({ jobId: "job", maxArticles: 100 });
    expect(rssGateway.historyStep).not.toHaveBeenCalled(); expect(host.textContent).toContain("失败重试预览（本段 1 项）"); expect(button("开始失败重试").disabled).toBe(true);
    await act(async () => host.querySelector<HTMLInputElement>(".rss-history-confirm input")!.click()); await click("开始失败重试");
    expect(rssGateway.historyStep).toHaveBeenCalledWith({ jobId: "job" }); expect(rssGateway.historyStep).not.toHaveBeenCalledWith(expect.objectContaining({ retryFailures: true }));
  });

  it("keeps the saved checkpoint when changing the retry batch size and prepares with the new limit", async () => {
    const failed: RssHistoryJob = { ...preview, status: "complete", candidates: [{ ...candidates[0], status: "failed", message: "failed" }], failedCount: 4 };
    const retryPreview: RssHistoryJob = { ...failed, status: "preview", candidates: [{ ...candidates[0], status: "pending", message: null }], retryingFailures: true };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => failed), historyPrepareRetry: vi.fn(async () => retryPreview) }); render(rssGateway); await settle();
    await setNumberInput("最多候选文章", 321);
    expect(host.textContent).toContain("预览失败重试"); expect(host.textContent).toContain("One");
    await click("预览失败重试"); expect(rssGateway.historyPrepareRetry).toHaveBeenCalledWith({ jobId: "job", maxArticles: 321 });
  });

  it("drops an in-flight local retry preview after close without starting a request step", async () => {
    const failed: RssHistoryJob = { ...preview, status: "paused", candidates: [{ ...candidates[0], status: "failed", message: "failed" }], failedCount: 1 };
    const pending = deferred<RssHistoryJob>();
    const rssGateway = gateway({ historyStatus: vi.fn(async () => failed), historyPrepareRetry: vi.fn(() => pending.promise) });
    const { onChanged } = render(rssGateway); await settle(); await click("预览失败重试");
    expect(rssGateway.historyStep).not.toHaveBeenCalled();
    act(() => root.unmount());
    await act(async () => pending.resolve({ ...failed, status: "preview", retryingFailures: true, candidates: [{ ...candidates[0], status: "pending" }] }));
    expect(onChanged).not.toHaveBeenCalled();
  });

  it("ignores a retry preview returned by a replaced gateway", async () => {
    const failed: RssHistoryJob = { ...preview, status: "complete", candidates: [{ ...candidates[0], status: "failed", message: "failed" }], failedCount: 1 };
    const oldPending = deferred<RssHistoryJob>(); const oldGateway = gateway({ historyStatus: vi.fn(async () => failed), historyPrepareRetry: vi.fn(() => oldPending.promise) }); const nextGateway = gateway();
    render(oldGateway); await settle(); await click("预览失败重试"); render(nextGateway); await settle();
    await act(async () => oldPending.resolve({ ...failed, retryingFailures: true, status: "preview", candidates: [{ ...candidates[0], status: "pending", message: null }] })); await settle();
    expect(host.textContent).not.toContain("失败重试预览"); expect(nextGateway.historyStatus).toHaveBeenCalledWith("feed"); expect(oldGateway.historyStep).not.toHaveBeenCalled();
  });

  it("disables retry preview while the current batch is pending", async () => {
    const paused: RssHistoryJob = { ...preview, status: "paused", candidates: [{ ...candidates[0], status: "failed", message: "failed" }, candidates[1]], failedCount: 1 };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => paused) });
    render(rssGateway); await settle();
    expect(button("继续补全").disabled).toBe(true);
    expect(button("预览失败重试").disabled).toBe(true);
    expect(rssGateway.historyPrepareRetry).not.toHaveBeenCalled();
    expect(host.textContent).toContain("全量未解决失败 1");
  });

  it("keeps the saved job when local retry preview fails", async () => {
    const failed: RssHistoryJob = { ...preview, status: "complete", candidates: [{ ...candidates[0], status: "failed", message: "failed" }], failedCount: 1 };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => failed), historyPrepareRetry: vi.fn(async () => Promise.reject(new Error("本机账本暂不可用"))) });
    render(rssGateway); await settle(); await click("预览失败重试");
    expect(host.querySelector('[role="alert"]')?.textContent).toContain("本机账本暂不可用"); expect(host.textContent).toContain("One"); expect(host.textContent).toContain("全量未解决失败 1");
    expect(rssGateway.historyStep).not.toHaveBeenCalled();
  });

  it("allows manual discovery continuation after the current batch finishes even with unresolved failures", async () => {
    const failed: RssHistoryJob = { ...preview, status: "complete", candidates: [{ ...candidates[0], status: "failed", message: "failed" }], failedCount: 12, hasMoreDiscovery: true };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => failed), historyResumeDiscovery: vi.fn(async () => failed) }); render(rssGateway); await settle();
    expect(button("继续发现历史链接").disabled).toBe(false); await click("继续发现历史链接");
    expect(rssGateway.historyResumeDiscovery).toHaveBeenCalledWith(expect.objectContaining({ jobId: "job" }));
  });

  it("keeps the saved checkpoint when changing next-segment limits and resumes with the new limits", async () => {
    const resumable: RssHistoryJob = { ...preview, status: "complete", candidates: [{ ...candidates[0], status: "failed", message: "failed" }], failedCount: 2, hasMoreDiscovery: true };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => resumable), historyResumeDiscovery: vi.fn(async () => resumable) }); render(rssGateway); await settle();
    await setNumberInput("最多目录页", 7); await setNumberInput("最多候选文章", 234);
    expect(host.textContent).toContain("继续发现历史链接"); expect(host.textContent).toContain("One");
    await click("继续发现历史链接"); expect(rssGateway.historyResumeDiscovery).toHaveBeenCalledWith({ jobId: "job", discoveryId: expect.any(String), maxPages: 7, maxArticles: 234 });
  });

  it("previews the next bounded retry batch only after the current retry batch has no pending items", async () => {
    const completedBatch: RssHistoryJob = { ...preview, status: "complete", candidates: [{ ...candidates[0], status: "failed", message: "failed again" }], failedCount: 8, retryingFailures: true };
    const nextBatch: RssHistoryJob = { ...completedBatch, status: "preview", candidates: [{ ...candidates[1], status: "pending", message: null }] };
    const rssGateway = gateway({ historyStatus: vi.fn(async () => completedBatch), historyPrepareRetry: vi.fn(async () => nextBatch) }); render(rssGateway); await settle();
    await click("预览下一批失败重试"); expect(rssGateway.historyPrepareRetry).toHaveBeenCalledWith({ jobId: "job", maxArticles: 100 }); expect(rssGateway.historyStep).not.toHaveBeenCalled(); expect(button("开始失败重试").disabled).toBe(true);
  });

  it("explains the read-only retry preview and all-job failure count in English", async () => {
    const failed: RssHistoryJob = { ...preview, status: "complete", candidates: [{ ...candidates[0], status: "failed", message: "failed" }], failedCount: 9 };
    render(gateway({ historyStatus: vi.fn(async () => failed) }), vi.fn(), vi.fn(), "en-US"); await settle();
    expect(host.textContent).toContain("Preview failed retries"); expect(host.textContent).toContain("makes no network requests"); expect(host.textContent).toContain("unresolved failures across the job 9");
  });

  it("localizes the source disclosure and controls in English", async () => {
    render(gateway(), vi.fn(), vi.fn(), "en-US"); await settle();
    expect(host.textContent).toContain("Backfill history"); expect(host.textContent).toContain("same-origin public directory"); expect(host.textContent).toContain("up to 2 additional same-origin legacy addresses"); expect(host.textContent).toContain("allowed by robots"); expect(host.textContent).toContain("noarchive"); expect(host.textContent).toContain("local full-text cache"); expect(host.textContent).toContain("Discover candidate articles");
  });

  it("shows a bounded message from structured native history errors", async () => {
    const instruction = "请求过快，请稍后重试。";
    render(gateway({ historyStatus: vi.fn(async () => Promise.reject({ code: "BACKOFF", message: `${instruction}${"x".repeat(600)}` })) }));
    await settle();
    expect(host.querySelector('[role="alert"]')?.textContent).toContain(instruction);
    expect(host.querySelector('[role="alert"]')?.textContent).toHaveLength(500);
  });

  it("pauses the original gateway job before loading a replacement gateway", async () => {
    const running = { ...preview, status: "running" as const }; const oldGateway = gateway({ historyStatus: vi.fn(async () => running) }); const nextGateway = gateway();
    render(oldGateway); await settle(); render(nextGateway); await settle();
    expect(oldGateway.historyPause).toHaveBeenCalledWith("job"); expect(nextGateway.historyStatus).toHaveBeenCalledWith("feed");
  });

  it("cancels a pending discovery on close and ignores its late result", async () => {
    const pending = deferred<RssHistoryJob>();
    const rssGateway = gateway({ historyDiscover: vi.fn(() => pending.promise) });
    const { onChanged, onClose } = render(rssGateway); await settle(); await click("发现候选文章");
    const discoveryId = vi.mocked(rssGateway.historyDiscover).mock.calls[0][0].discoveryId;
    await act(async () => host.querySelector<HTMLButtonElement>('.rss-history-backfill header button')!.click());
    expect(rssGateway.historyCancelDiscovery).toHaveBeenCalledWith(discoveryId); expect(onClose).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(preview)); await settle();
    expect(host.textContent).not.toContain("本段候选文章（2）"); expect(onChanged).not.toHaveBeenCalled();
  });

  it("keeps a same-id replacement discovery bound to its new gateway", async () => {
    vi.spyOn(globalThis.crypto, "randomUUID").mockReturnValue("00000000-0000-4000-8000-000000000001");
    const oldPending = deferred<RssHistoryJob>(); const nextPending = deferred<RssHistoryJob>();
    const oldGateway = gateway({ historyDiscover: vi.fn(() => oldPending.promise) });
    const nextGateway = gateway({ historyDiscover: vi.fn(() => nextPending.promise) });
    render(oldGateway); await settle(); await click("发现候选文章");
    render(nextGateway); await settle();
    expect(oldGateway.historyCancelDiscovery).toHaveBeenCalledWith("00000000-0000-4000-8000-000000000001");
    await click("发现候选文章");
    await act(async () => oldPending.resolve(preview)); await settle();
    await act(async () => host.querySelector<HTMLButtonElement>('.rss-history-backfill header button')!.click());
    expect(nextGateway.historyCancelDiscovery).toHaveBeenCalledWith("00000000-0000-4000-8000-000000000001");
  });
});
