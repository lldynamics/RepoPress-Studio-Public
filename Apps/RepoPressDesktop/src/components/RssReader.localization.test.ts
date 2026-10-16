import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RssArticle, RssArticlePage, RssFeed, RssFullTextRecord, RssGateway, RssPreferences, RssSnapshot } from "../features/rss/contracts";
import { I18nProvider } from "../i18n/i18n";
import { rssMessages } from "../i18n/rssMessages";
import { RssReader, type RssArticleWorkflowInput, type RssReaderProps } from "./RssReader";

vi.mock("../features/translation/RssTranslationPanel", () => ({ RssTranslationPanel: () => null }));
vi.mock("../features/translation/RssBatchTranslationDialog", () => ({ RssBatchTranslationDialog: () => null }));
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

const preferences: RssPreferences = { automaticPruningEnabled: false, retentionDays: 90, feedBodyOfflineCacheEnabled: false, privateNetworkAccessEnabled: false, backgroundRefreshEnabled: true, backgroundRefreshIntervalMinutes: 30, automaticMarkReadAtEndEnabled: true, automaticFullTextExtractionEnabled: false, offlineCacheFullTextOnRefreshEnabled: false, remoteImagesEnabled: false, offlineTranslationCacheEnabled: false, offlineTranslationRetentionDays: 30, offlineTranslationMaxMiB: 100, automaticLocalPretranslationOnRefreshEnabled: false };
const feed: RssFeed = { id: "feed", title: "设置 {count}", url: "https://raw.example/设置/{count}", siteUrl: null, iconUrl: null, addedAt: 1, lastUpdatedAt: 2, etag: null, lastModified: null, lastError: null, lastIssue: { stage: "transport", category: "raw", retryStrategy: "manual", retryAt: null, userMessage: "偏好 {count}", technicalDetail: null, occurredAt: 2 }, lastRefreshAttemptAt: 2, refreshFailureCount: 1, nextRetryAt: null, lastRefreshDuration: null };
const article: RssArticle = { id: "article", feedId: feed.id, title: "标题 {count}", link: "https://raw.example/article/{count}", coverUrl: null, author: "作者 {count}", publishedAt: 1_700_000_000, readableSummary: "摘要 设置 {count}", fetchedAt: 1_700_000_001, readAt: null, isStarred: false, tags: ["标签 {count}"], summaryHtml: "<p>正文 设置 {count}</p>", contentHtml: "", webPageSnapshotHtml: null };
const snapshot: RssSnapshot = { feeds: [feed], articles: [article], articleCount: 1, unreadCount: 1, starredCount: 0, unreadCountByFeed: { [feed.id]: 1 }, authors: [article.author!], tags: article.tags, statusMessage: null, errorMessage: null };
const page: RssArticlePage = { articles: [article], totalCount: 1, hasMore: false };

function deferred<T>() { let resolve!: (value: T) => void; let reject!: (reason: unknown) => void; const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; }); return { promise, resolve, reject }; }
function makeGateway(): RssGateway {
  return {
    snapshot: vi.fn(async () => snapshot), discover: vi.fn(async () => []), addFeed: vi.fn(async () => feed), updateFeedUrl: vi.fn(async () => feed), removeFeed: vi.fn(async () => ({ undoToken: "undo-feed" })),
    refreshFeed: vi.fn(async () => ({ successCount: 1, failureCount: 0, skippedCount: 0 })), refreshAll: vi.fn(async () => ({ successCount: 1, failureCount: 0, skippedCount: 0 })), listArticles: vi.fn(async () => page), getArticle: vi.fn(async () => article), updateArticleState: vi.fn(async () => article), markAllRead: vi.fn(async () => ({ changedCount: 1, undoToken: "undo-read" })), undoMarkAllRead: vi.fn(async () => undefined), undoRemoveFeed: vi.fn(async () => undefined),
    fetchFullText: vi.fn(async (_articleId, _force): Promise<RssFullTextRecord> => ({ articleId: article.id, status: "ready", contentHtml: "<p>full</p>", plainText: "full", sourceUrl: article.link, resolvedUrl: article.link, extractorIdentifier: "test", extractorVersion: "1", sourceEtag: null, sourceLastModified: null, sourceContentHash: null, confidence: 1, attemptedAt: 1, retryAfter: null, failureMessage: null })), fetchCover: vi.fn(async () => null), listHighlights: vi.fn(async () => []), saveHighlight: vi.fn(async (input) => ({ id: "highlight", ...input, createdAt: 1, updatedAt: 1 })), deleteHighlight: vi.fn(async () => undefined), getReadingProgress: vi.fn(async () => ({ articleId: article.id, progress: .4, revision: 7, updatedAt: 1 })), saveReadingProgress: vi.fn(async (input) => ({ ...input, updatedAt: 1 })),
    importOpml: vi.fn(async () => ({ importedCount: 1, skippedCount: 0 })), exportOpml: vi.fn(async () => "<opml>设置 {count}</opml>"), reviewOpml: vi.fn(async (input) => ({ direction: input.direction, fingerprint: "review", totalCount: 1, affectedCount: 0, blockedCount: 0, findings: [] })), executeOpml: vi.fn(async () => ({ opml: null, importedCount: 1, skippedCount: 0, exportedCount: 0, excludedCount: 0 })), historyDiscover: vi.fn(async () => { throw new Error("unused"); }), historyResumeDiscovery: vi.fn(async () => { throw new Error("unused"); }), historyCancelDiscovery: vi.fn(async () => undefined), historyStatus: vi.fn(async () => null), historyList: vi.fn(async () => []), historyClear: vi.fn(async () => undefined), historyPrepareRetry: vi.fn(async () => { throw new Error("unused"); }), historyStep: vi.fn(async () => { throw new Error("unused"); }), historyPause: vi.fn(async () => { throw new Error("unused"); }), getPreferences: vi.fn(async () => preferences), updatePreferences: vi.fn(async (value) => value), prune: vi.fn(async () => ({ removedArticleCount: 1, removedMediaAssetCount: 0, cutoffDate: 1 })), exportBackup: vi.fn(async () => "backup 设置 {count}"), inspectBackup: vi.fn(async () => ({ databaseSchemaVersion: 2, feedCount: 1, articleCount: 1, highlightCount: 0, indexedArticleCount: 1 })), restoreBackup: vi.fn(async () => ({ databaseSchemaVersion: 2, feedCount: 1, articleCount: 1, highlightCount: 0, indexedArticleCount: 1 })),
    getOfflineTranslation: vi.fn(async () => null), saveOfflineTranslation: vi.fn(async () => { throw new Error("unused"); }), deleteOfflineTranslation: vi.fn(async () => undefined), offlineTranslationCacheStatus: vi.fn(async () => ({ entryCount: 1, totalBytes: 1024, maxBytes: 1024 * 1024, expiredCount: 0 })), pruneOfflineTranslations: vi.fn(async () => ({ removedCount: 0, freedBytes: 0, remainingCount: 1, remainingBytes: 1024 })), clearOfflineTranslations: vi.fn(async () => ({ removedCount: 1, freedBytes: 1024, remainingCount: 0, remainingBytes: 0 })),
  };
}

let host: HTMLDivElement; let root: Root; let gateway: RssGateway; let props: RssReaderProps;
function render(locale: "zh-CN" | "en-US", update: Partial<RssReaderProps> = {}) { props = { ...props, ...update }; act(() => root.render(createElement(I18nProvider, { locale, children: createElement(RssReader, props) }))); }
async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }
function button(label: string | RegExp) { return [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => typeof label === "string" ? item.textContent === label || item.getAttribute("aria-label") === label : label.test(item.textContent ?? "") || label.test(item.getAttribute("aria-label") ?? "")); }
async function click(label: string | RegExp) { const target = button(label); if (!target) throw new Error(`Missing button ${String(label)}`); await act(async () => target.click()); await settle(); }
async function selectArticle() { const target = host.querySelector<HTMLButtonElement>(".rss-row-main"); if (!target) throw new Error("Missing article row"); await act(async () => target.click()); await settle(); }

beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = makeGateway(); props = { gateway, active: true }; });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); });

describe("RSS reader live localization", () => {
  it("keeps the existing-article backfill copy localized accurately", () => {
    expect(rssMessages["同时补齐已有文章缺失或仅含摘要、截断内容的正文（写入本机全文缓存，原文和阅读状态不变）"]).toContain("body of existing articles when it is missing, contains only a summary, or is truncated");
    expect(rssMessages["已就绪的本机全文缓存会优先复用；短但完整的文章不会仅因篇幅短而请求。"]).toContain("A short but complete article is not requested just because it is short.");
  });

  it("opens the localized history queue from the sidebar without starting discovery", async () => {
    render("en-US"); await settle();
    await click("History backfill queue");
    expect(gateway.historyList).toHaveBeenCalledTimes(1); expect(gateway.historyDiscover).not.toHaveBeenCalled(); expect(gateway.historyResumeDiscovery).not.toHaveBeenCalled();
    expect(host.querySelector('[role="dialog"]')?.getAttribute("aria-label")).toBe("History backfill queue");
  });

  it("keeps pending snapshot and article-list requests stable through zh to en to zh", async () => {
    const pendingSnapshot = deferred<RssSnapshot>(); const pendingPage = deferred<RssArticlePage>();
    vi.mocked(gateway.snapshot).mockReturnValueOnce(pendingSnapshot.promise); vi.mocked(gateway.listArticles).mockReturnValueOnce(pendingPage.promise);
    render("zh-CN"); render("en-US"); render("zh-CN");
    expect(gateway.snapshot).toHaveBeenCalledTimes(1); expect(gateway.getPreferences).toHaveBeenCalledTimes(1); expect(gateway.listArticles).toHaveBeenCalledTimes(1);
    await act(async () => { pendingSnapshot.resolve(snapshot); pendingPage.resolve(page); }); await settle();
    expect(host.textContent).toContain("订阅"); expect(host.textContent).toContain(article.title); expect(gateway.snapshot).toHaveBeenCalledTimes(1); expect(gateway.listArticles).toHaveBeenCalledTimes(1);
  });

  it("does not repeat pending getArticle or full-text requests when locale changes", async () => {
    render("zh-CN"); await settle(); const pendingArticle = deferred<RssArticle | null>(); vi.mocked(gateway.getArticle).mockReturnValueOnce(pendingArticle.promise);
    await selectArticle(); render("en-US"); expect(gateway.getArticle).toHaveBeenCalledTimes(1);
    await act(async () => pendingArticle.resolve(article)); await settle(); expect(host.textContent).toContain("Reading progress 40%");
    const pendingFullText = deferred<Awaited<ReturnType<RssGateway["fetchFullText"]>>>(); vi.mocked(gateway.fetchFullText).mockReturnValueOnce(pendingFullText.promise);
    await click("Extract full text"); render("zh-CN"); render("en-US"); expect(gateway.fetchFullText).toHaveBeenCalledTimes(1);
    await act(async () => pendingFullText.resolve({ articleId: article.id, status: "failed", contentHtml: "", plainText: "", sourceUrl: article.link, resolvedUrl: null, extractorIdentifier: "raw", extractorVersion: "1", sourceEtag: null, sourceLastModified: null, sourceContentHash: null, confidence: 0, attemptedAt: 1, retryAfter: null, failureMessage: "设置 {count}" })); await settle();
    expect(host.querySelector('[role="alert"]')?.textContent).toContain("设置 {count}"); expect(host.textContent).toContain("设置 {count}");
    vi.mocked(gateway.fetchFullText).mockResolvedValueOnce({ articleId: article.id, status: "failed", contentHtml: "", plainText: "", sourceUrl: article.link, resolvedUrl: null, extractorIdentifier: "raw", extractorVersion: "1", sourceEtag: null, sourceLastModified: null, sourceContentHash: null, confidence: 0, attemptedAt: 2, retryAfter: null, failureMessage: "" });
    await click("Retry full text"); expect(host.querySelector('[role="alert"]')).toBeNull();
  });

  it("preserves filters, selection, reading controls, and preferences across locale changes", async () => {
    render("zh-CN", { onSaveToKnowledge: vi.fn(async () => undefined) }); await settle();
    await act(async () => host.querySelector<HTMLButtonElement>(".rss-feed")!.click()); await settle();
    const search = host.querySelector<HTMLInputElement>('.rss-filters input[type="text"], .rss-filters input:not([type])')!; const unread = host.querySelector<HTMLInputElement>('.rss-filters input[type="checkbox"]')!; const selects = host.querySelectorAll<HTMLSelectElement>(".rss-filters select");
    await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "needle {count}"); search.dispatchEvent(new Event("input", { bubbles: true })); unread.click(); selects[0].value = article.author!; selects[0].dispatchEvent(new Event("change", { bubbles: true })); selects[1].value = article.tags[0]; selects[1].dispatchEvent(new Event("change", { bubbles: true })); selects[2].value = "oldest"; selects[2].dispatchEvent(new Event("change", { bubbles: true })); }); await settle();
    const batchSelection = host.querySelector<HTMLInputElement>(".rss-row-select input")!; await act(async () => batchSelection.click());
    await selectArticle(); const theme = host.querySelector<HTMLSelectElement>('.rss-reading-controls select')!; await act(async () => { theme.value = "dark"; theme.dispatchEvent(new Event("change", { bubbles: true })); });
    await click("偏好"); const retention = [...host.querySelectorAll<HTMLInputElement>('input[type="number"]')].find((item) => item.value === "90")!; await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(retention, "365"); retention.dispatchEvent(new Event("input", { bubbles: true })); });
    const listCalls = vi.mocked(gateway.listArticles).mock.calls.length; render("zh-CN"); render("en-US");
    expect(search.value).toBe("needle {count}"); expect(unread.checked).toBe(true); expect(selects[0].value).toBe(article.author); expect(selects[1].value).toBe(article.tags[0]); expect(selects[2].value).toBe("oldest"); expect(batchSelection.checked).toBe(true); expect(theme.value).toBe("dark"); expect(retention.value).toBe("365"); expect(host.textContent).toContain(feed.title); expect(host.textContent).toContain("Reading progress 40%"); expect(gateway.listArticles).toHaveBeenCalledTimes(listCalls);
  });

  it("rerenders delayed local notices but keeps raw gateway messages literal", async () => {
    render("zh-CN"); await settle(); const marked = deferred<{ changedCount: number; undoToken: string | null }>(); vi.mocked(gateway.markAllRead).mockReturnValueOnce(marked.promise);
    await click("全部标为已读"); render("en-US"); await act(async () => marked.resolve({ changedCount: 1, undoToken: "undo-read" })); await settle();
    expect(host.textContent).toContain("Marked 1 articles as read."); render("zh-CN"); expect(host.textContent).toContain("已标记 1 篇文章为已读。");
    vi.mocked(gateway.refreshAll).mockResolvedValueOnce({ successCount: 1, failureCount: 0, skippedCount: 0, statusText: "" }); render("en-US"); await click("Refresh all");
    expect(host.querySelector('.rss-notice[role="status"]')).toBeNull(); expect(host.textContent).not.toContain("Refresh complete");
    vi.mocked(gateway.refreshAll).mockResolvedValueOnce({ successCount: 0, failureCount: 1, skippedCount: 0, statusText: "设置 {count}" }); render("en-US"); await click("Refresh all");
    expect(host.querySelector('.rss-notice[role="status"]')?.textContent).toContain("设置 {count}"); expect(host.textContent).not.toContain("Settings {count}");
    vi.mocked(gateway.refreshAll).mockRejectedValueOnce(new Error("设置")); await click("Refresh all"); expect(host.querySelector('.rss-notice[role="alert"]')?.textContent).toContain("设置"); expect(host.querySelector('.rss-notice[role="alert"]')?.textContent).not.toContain("Settings");
    vi.mocked(gateway.refreshAll).mockRejectedValueOnce("标题"); await click("Refresh all"); expect(host.querySelector('.rss-notice[role="alert"]')?.textContent).toContain("The RSS operation failed. Try again later."); expect(host.querySelector('.rss-notice[role="alert"]')?.textContent).not.toContain("标题");
  });

  it("uses the click-time language for confirm and prompt while preserving feed URLs and undo tokens", async () => {
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true); const prompt = vi.spyOn(window, "prompt").mockReturnValue("https://changed.example/设置/{count}");
    render("en-US"); await settle(); await click(`Edit ${feed.title} address`);
    expect(prompt).toHaveBeenCalledWith("Edit RSS / Atom address", feed.url); expect(gateway.updateFeedUrl).toHaveBeenCalledWith(feed.id, "https://changed.example/设置/{count}");
    await click(`Delete ${feed.title}`); expect(confirm).toHaveBeenCalledWith(`Delete “${feed.title}” and its local article cache?`); expect(host.textContent).toContain(`Deleted “${feed.title}”.`);
    await click("Undo"); expect(gateway.undoRemoveFeed).toHaveBeenCalledWith("undo-feed");
    render("zh-CN"); await click(`删除 ${feed.title}`); expect(confirm).toHaveBeenLastCalledWith(`删除“${feed.title}”及其本地文章缓存？`);
  });

  it("preserves raw article fields and workflow payloads that look like catalog templates", async () => {
    const save = vi.fn(async (_input: RssArticleWorkflowInput) => undefined); const insert = vi.fn(async (_input: RssArticleWorkflowInput) => undefined); render("en-US", { onSaveToKnowledge: save, onInsertReference: insert }); await settle();
    expect(host.textContent).toContain(article.title); expect(host.textContent).toContain(article.author!); expect(host.textContent).toContain(article.tags[0]); expect(host.textContent).toContain(feed.lastIssue!.userMessage); expect(host.textContent).not.toContain("Title {count}");
    await selectArticle(); await click("Save to library");
    const savedInput = save.mock.calls[0]![0]; expect(save).toHaveBeenCalledTimes(1); expect(savedInput.article).toBe(article); expect(savedInput.feed).toBe(feed); expect(savedInput.text).toContain("正文 设置 {count}");
    vi.spyOn(window, "getSelection").mockReturnValue({ toString: () => "选择 设置 {count}", removeAllRanges: vi.fn() } as unknown as Selection);
    await act(async () => host.querySelector<HTMLElement>(".rss-article-body")!.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }))); await settle(); const selectionInsert = [...host.querySelectorAll<HTMLButtonElement>(".rss-selection-bar button")].find((item) => item.textContent === "Insert into current draft")!; await act(async () => selectionInsert.click()); await settle();
    expect(insert.mock.calls[0]![0]).toMatchObject({ article, feed, text: "选择 设置 {count}" });
    render("zh-CN"); render("en-US"); expect(save).toHaveBeenCalledTimes(1); expect(insert).toHaveBeenCalledTimes(1); expect(host.textContent).toContain(article.title);
  });
});
