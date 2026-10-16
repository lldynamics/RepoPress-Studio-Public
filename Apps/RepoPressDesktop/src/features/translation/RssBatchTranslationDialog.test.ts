import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { RssArticle, RssFeed, RssGateway } from "../rss/contracts";
import { RssBatchTranslationDialog, type RssBatchTranslationDialogProps } from "./RssBatchTranslationDialog";
import { TranslationSessionCache } from "./translationSessionCache";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let root: Root | null = null;
let container: HTMLDivElement | null = null;
const feed: RssFeed = { id: "feed-a", title: "Feed A", url: "https://feed.test", siteUrl: null, iconUrl: null, addedAt: 0, lastUpdatedAt: null, etag: null, lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: null, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: null };
const article = (id: string): RssArticle => ({ id, feedId: feed.id, title: `Article ${id}`, link: null, coverUrl: null, author: null, publishedAt: null, readableSummary: `Body ${id}`, fetchedAt: 0, readAt: null, isStarred: false, tags: [], summaryHtml: `<p>Body ${id}</p>`, contentHtml: "", webPageSnapshotHtml: null });
const plan = (id: string, endpoint = "http://127.0.0.1:5000") => ({ planId: `plan-${id}`, provider: endpoint.startsWith("https") ? "openai_compatible" as const : "libretranslate_local" as const, endpoint, model: endpoint.startsWith("https") ? "test-model" : "", sourceLanguage: "auto", targetLanguage: "zh", textBytes: 10, glossaryCount: 0, expiresAt: new Date(Date.now() + 60_000).toISOString(), summary: "test", warnings: [] });

afterEach(() => { if (root) act(() => root?.unmount()); root = null; container?.remove(); container = null; localStorage.clear(); });

function rss(ids = ["a", "b"]) {
  return {
    listArticles: vi.fn().mockResolvedValue({ articles: ids.map((id) => article(id)), totalCount: ids.length, hasMore: false }),
    getArticle: vi.fn().mockImplementation(async (id: string) => article(id)),
  } as Pick<RssGateway, "listArticles" | "getArticle">;
}

function translation(overrides: Partial<NonNullable<RssBatchTranslationDialogProps["translationGateway"]>> = {}) {
  return { planTextTranslation: vi.fn().mockImplementation(async (request) => plan(request.text)), executeTextTranslation: vi.fn().mockResolvedValue({ translatedText: "译文", detectedSourceLanguage: "en", provider: "libretranslate_local", model: "", targetLanguage: "zh" }), ...overrides } as NonNullable<RssBatchTranslationDialogProps["translationGateway"]>;
}

function mount(overrides: Partial<RssBatchTranslationDialogProps> = {}) {
  container = document.createElement("div"); document.body.append(container);
  root = createRoot(container);
  const props: RssBatchTranslationDialogProps = { open: true, onClose: vi.fn(), feeds: [feed], rssGateway: rss(), translationGateway: translation(), sessionCache: new TranslationSessionCache(), ...overrides };
  act(() => root?.render(createElement(RssBatchTranslationDialog, props)));
  return props;
}

async function click(label: string) {
  const button = [...container!.querySelectorAll<HTMLButtonElement>("button")].find((value) => value.textContent === label);
  expect(button, `button ${label}`).toBeTruthy();
  await act(async () => { button!.click(); await new Promise((resolve) => window.setTimeout(resolve, 0)); });
}

async function flush() { await act(async () => { await new Promise((resolve) => window.setTimeout(resolve, 0)); }); }

function deferred<T>() { let resolve!: (value: T) => void; let reject!: (reason?: unknown) => void; const promise = new Promise<T>((next, fail) => { resolve = next; reject = fail; }); return { promise, resolve, reject }; }

describe("RSS batch pretranslation", () => {
  it("uses offline records before planning and persists confirmed successes", async () => {
    const offline = { getOfflineTranslation: vi.fn().mockResolvedValue({ translatedText: "离线", detectedSourceLanguage: "en", provider: "libretranslate_local", model: "", targetLanguage: "zh" }), saveOfflineTranslation: vi.fn().mockResolvedValue({}) };
    const service = translation();
    const props = mount({ rssGateway: rss(["a"]), translationGateway: service, offlineTranslationGateway: offline as never, offlineTranslationEnabled: true });
    await click("准备计划");
    expect(service.planTextTranslation).not.toHaveBeenCalled();
    expect(service.executeTextTranslation).not.toHaveBeenCalled();
    expect(offline.getOfflineTranslation).toHaveBeenCalledTimes(1);

    props.sessionCache.clear();
    offline.getOfflineTranslation.mockResolvedValueOnce(null);
    await click("准备计划"); await click("确认并开始"); await flush();
    expect(offline.saveOfflineTranslation).toHaveBeenCalledWith(expect.objectContaining({ articleId: "a" }));
  });

  it("refresh enqueue skips hosted providers and makes local plans without execution", async () => {
    localStorage.setItem("repopress.rss.translation.config.v1", JSON.stringify({ provider: "openai_compatible", endpoint: "https://api.example.test/v1", model: "m", sourceLanguage: "auto", targetLanguage: "zh", strategy: "manual" }));
    const hosted = translation();
    mount({ rssGateway: rss(["a"]), translationGateway: hosted, refreshEnqueue: { id: 1, feedId: feed.id } });
    await flush(); await flush();
    expect(hosted.planTextTranslation).not.toHaveBeenCalled();
    expect(hosted.executeTextTranslation).not.toHaveBeenCalled();

    localStorage.setItem("repopress.rss.translation.config.v1", JSON.stringify({ provider: "libretranslate_local", endpoint: "http://127.0.0.1:5000", model: "", sourceLanguage: "auto", targetLanguage: "zh", strategy: "manual" }));
    act(() => root?.unmount()); root = null; container?.remove(); container = null;
    const local = translation();
    mount({ rssGateway: rss(["b"]), translationGateway: local, refreshEnqueue: { id: 2, feedId: feed.id } });
    await flush(); await flush();
    expect(local.planTextTranslation).toHaveBeenCalledTimes(1);
    expect(local.executeTextTranslation).not.toHaveBeenCalled();
    expect([...container!.querySelectorAll<HTMLButtonElement>("button")].some((button) => button.textContent === "确认并开始")).toBe(true);
  });
  it("prepares without executing, and surfaces hosted destination warning", async () => {
    localStorage.setItem("repopress.rss.translation.config.v1", JSON.stringify({ provider: "openai_compatible", endpoint: "https://api.example.test/v1", model: "m", sourceLanguage: "auto", targetLanguage: "zh", strategy: "manual" }));
    const service = translation({ planTextTranslation: vi.fn().mockResolvedValue(plan("x", "https://api.example.test/v1")) });
    mount({ translationGateway: service });
    await click("准备计划");
    expect(service.planTextTranslation).toHaveBeenCalledTimes(2);
    expect(service.executeTextTranslation).not.toHaveBeenCalled();
    expect(container?.textContent).toContain("外部 HTTPS 托管 AI 服务");
  });

  it("never exceeds chosen execution concurrency and writes successful results to cache", async () => {
    const pending = new Map<string, ReturnType<typeof deferred<{ translatedText: string; detectedSourceLanguage: null; provider: "libretranslate_local"; model: string; targetLanguage: string }>>>();
    let active = 0; let peak = 0;
    const service = translation({ executeTextTranslation: vi.fn((request) => { active += 1; peak = Math.max(peak, active); const gate = deferred<{ translatedText: string; detectedSourceLanguage: null; provider: "libretranslate_local"; model: string; targetLanguage: string }>(); pending.set(request.planId, gate); return gate.promise.finally(() => { active -= 1; }); }) });
    const cache = new TranslationSessionCache(); const onCacheChange = vi.fn();
    mount({ rssGateway: rss(["a", "b", "c"]), translationGateway: service, sessionCache: cache, onCacheChange });
    await click("准备计划");
    await click("确认并开始");
    await flush();
    expect(peak).toBe(2);
    for (const gate of pending.values()) gate.resolve({ translatedText: "译文", detectedSourceLanguage: null, provider: "libretranslate_local", model: "", targetLanguage: "zh" });
    await flush(); await flush();
    for (const gate of pending.values()) gate.resolve({ translatedText: "译文", detectedSourceLanguage: null, provider: "libretranslate_local", model: "", targetLanguage: "zh" });
    await flush(); await flush();
    expect(onCacheChange).toHaveBeenCalledTimes(3);
  });

  it("pauses new work and resumes planned items", async () => {
    const first = deferred<{ translatedText: string; detectedSourceLanguage: null; provider: "libretranslate_local"; model: string; targetLanguage: string }>();
    const service = translation({ executeTextTranslation: vi.fn().mockReturnValueOnce(first.promise).mockResolvedValue({ translatedText: "next", detectedSourceLanguage: null, provider: "libretranslate_local", model: "", targetLanguage: "zh" }) });
    mount({ rssGateway: rss(["a", "b"]), translationGateway: service });
    const select = container!.querySelectorAll<HTMLSelectElement>("select")[2];
    await act(async () => { select.value = "1"; select.dispatchEvent(new Event("change", { bubbles: true })); });
    await click("准备计划"); await click("确认并开始"); await click("暂停");
    first.resolve({ translatedText: "first", detectedSourceLanguage: null, provider: "libretranslate_local", model: "", targetLanguage: "zh" });
    await flush(); await flush();
    expect(service.executeTextTranslation).toHaveBeenCalledTimes(1);
    await click("恢复"); await flush();
    expect(service.executeTextTranslation).toHaveBeenCalledTimes(2);
  });

  it("uses cached articles without requesting a plan or execution", async () => {
    const service = translation(); const cache = new TranslationSessionCache();
    cache.set(JSON.stringify(["repopress-rss-translation-session-v1", "a", "article", "libretranslate_local", "http://127.0.0.1:5000", "", "auto", "zh", [], "Body a"]), { translatedText: "cached", detectedSourceLanguage: "en", provider: "libretranslate_local", model: "", targetLanguage: "zh" });
    mount({ rssGateway: rss(["a"]), translationGateway: service, sessionCache: cache });
    await click("准备计划");
    expect(service.planTextTranslation).not.toHaveBeenCalled();
    expect(service.executeTextTranslation).not.toHaveBeenCalled();
    expect(container?.textContent).toContain("已缓存 1");
    await click("清空记录");
    expect(container?.textContent).not.toContain("任务（1 篇）");
  });

  it("replanning failures returns to confirmation and minimizing retains the queue", async () => {
    const service = translation({ executeTextTranslation: vi.fn().mockRejectedValue(new Error("offline")) });
    const onClose = vi.fn(); const props = mount({ rssGateway: rss(["a"]), translationGateway: service, onClose });
    await click("准备计划"); await click("确认并开始"); await flush();
    await click("为失败项重新生成计划");
    expect([...container!.querySelectorAll<HTMLButtonElement>("button")].some((button) => button.textContent === "确认并开始")).toBe(true);
    expect(service.executeTextTranslation).toHaveBeenCalledTimes(1);
    await act(async () => { container!.querySelector<HTMLButtonElement>('button[aria-label="最小化批量预翻译"]')!.click(); });
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(container?.textContent).toContain("批量预翻译：等待确认（1）");
    expect(props.sessionCache.size).toBe(0);
  });

  it("does not create an orphaned plan when unmounted during article loading", async () => {
    const pendingArticle = deferred<RssArticle>();
    const rssGateway = rss(["a"]);
    rssGateway.getArticle = vi.fn().mockReturnValue(pendingArticle.promise);
    const service = translation();
    mount({ rssGateway, translationGateway: service });

    const prepare = [...container!.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "准备计划")!;
    await act(async () => { prepare.click(); await Promise.resolve(); });
    act(() => root?.unmount());
    root = null;
    pendingArticle.resolve(article("a"));
    await act(async () => { await pendingArticle.promise; await Promise.resolve(); });

    expect(service.planTextTranslation).not.toHaveBeenCalled();
    expect(service.executeTextTranslation).not.toHaveBeenCalled();
  });
});
