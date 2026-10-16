import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AiCredentialStatusSnapshot, PlanTextTranslationRequest, TextTranslationPlan, TextTranslationResult } from "../../contracts/repository";
import { I18nProvider } from "../../i18n/i18n";
import type { RssArticle, RssFeed, RssGateway } from "../rss/contracts";
import { RssBatchTranslationDialog, type RssBatchTranslationDialogProps } from "./RssBatchTranslationDialog";
import { RssTranslationPanel, type RssTranslationPanelProps } from "./RssTranslationPanel";
import { buildTranslationSessionCacheKey, TranslationSessionCache } from "./translationSessionCache";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

const feed: RssFeed = { id: "feed", title: "设置 {count}", url: "https://feed.test", siteUrl: null, iconUrl: null, addedAt: 0, lastUpdatedAt: null, etag: null, lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: null, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: null };
const article = (id: string, body = `Body ${id}`): RssArticle => ({ id, feedId: feed.id, title: `标题 ${id} {count}`, link: null, coverUrl: null, author: null, publishedAt: null, readableSummary: body, fetchedAt: 0, readAt: null, isStarred: false, tags: [], summaryHtml: `<p>${body}</p>`, contentHtml: "", webPageSnapshotHtml: null });
const translationResult = (translatedText = "译文 设置 {count}"): TextTranslationResult => ({ translatedText, detectedSourceLanguage: "设置", provider: "libretranslate_local", model: "", targetLanguage: "zh" });
const plan = (overrides: Partial<TextTranslationPlan> = {}): TextTranslationPlan => ({ planId: "plan", provider: "libretranslate_local", endpoint: "http://127.0.0.1:5000", model: "", sourceLanguage: "auto", targetLanguage: "zh", textBytes: 16, glossaryCount: 0, expiresAt: new Date(Date.now() + 60_000).toISOString(), summary: "设置 {count}", warnings: [], ...overrides });
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (reason?: unknown) => void; const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; }); return { promise, resolve, reject }; }

let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); localStorage.clear(); vi.restoreAllMocks(); });

function renderPanel(locale: "zh-CN" | "en-US", props: RssTranslationPanelProps) {
  act(() => root.render(createElement(I18nProvider, { locale, children: createElement(RssTranslationPanel, props) })));
}
function renderBatch(locale: "zh-CN" | "en-US", props: RssBatchTranslationDialogProps) {
  act(() => root.render(createElement(I18nProvider, { locale, children: createElement(RssBatchTranslationDialog, props) })));
}
async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }
async function click(label: string | RegExp) {
  const button = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => typeof label === "string" ? item.textContent === label || item.getAttribute("aria-label") === label : label.test(item.textContent ?? "") || label.test(item.getAttribute("aria-label") ?? ""));
  if (!button) throw new Error(`Missing button ${String(label)}`);
  await act(async () => button.click()); await settle();
}
async function select(element: HTMLSelectElement, value: string) { await act(async () => { element.value = value; element.dispatchEvent(new Event("change", { bubbles: true })); }); }
async function input(element: HTMLInputElement | HTMLTextAreaElement, value: string) { await act(async () => { Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element), "value")?.set?.call(element, value); element.dispatchEvent(new Event("input", { bubbles: true })); }); }

function panelGateway(overrides: Partial<NonNullable<RssTranslationPanelProps["gateway"]>> = {}): NonNullable<RssTranslationPanelProps["gateway"]> {
  return {
    planTextTranslation: vi.fn(async () => plan()), executeTextTranslation: vi.fn(async () => translationResult()),
    aiCredentialStatus: vi.fn(async () => ({ configured: false, storage: "none", sessionOnly: false, secretServiceAvailable: true, warning: null })),
    storeAiCredential: vi.fn(async () => ({ configured: true, storage: "memory", sessionOnly: true, secretServiceAvailable: false, warning: null })),
    deleteAiCredential: vi.fn(async () => ({ configured: false, storage: "none", sessionOnly: false, secretServiceAvailable: true, warning: null })), ...overrides,
  } as NonNullable<RssTranslationPanelProps["gateway"]>;
}
function batchRss(ids = ["a", "b"]): Pick<RssGateway, "listArticles" | "getArticle"> {
  return { listArticles: vi.fn(async () => ({ articles: ids.map((id) => article(id)), totalCount: ids.length, hasMore: false })), getArticle: vi.fn(async (id: string) => article(id)) };
}
function batchGateway(overrides: Partial<NonNullable<RssBatchTranslationDialogProps["translationGateway"]>> = {}): NonNullable<RssBatchTranslationDialogProps["translationGateway"]> {
  return { planTextTranslation: vi.fn(async (request: PlanTextTranslationRequest) => plan({ planId: `plan-${request.text}`, textBytes: request.text.length })), executeTextTranslation: vi.fn(async () => translationResult()), ...overrides };
}

describe("RSS translation live localization", () => {
  it("keeps pending credential state and uses the click-time language for deletion", async () => {
    localStorage.setItem("repopress.rss.translation.config.v1", JSON.stringify({ provider: "openai_compatible", endpoint: "https://api.example.test/v1", model: "model-{count}", sourceLanguage: "auto", targetLanguage: "zh", strategy: "manual" }));
    const pending = deferred<AiCredentialStatusSnapshot>();
    const gateway = panelGateway({ aiCredentialStatus: vi.fn(() => pending.promise) });
    const props: RssTranslationPanelProps = { articleId: "a", articleText: "Source 设置 {count}", selectionText: "Selection 设置 {count}", gateway };
    renderPanel("zh-CN", props);
    const token = host.querySelector<HTMLInputElement>('.rss-translation-credential input[type="password"]')!;
    await input(token, "secret-value"); await click("检查凭据");
    renderPanel("en-US", props); renderPanel("zh-CN", props);
    expect(token.value).toBe("secret-value"); expect(gateway.aiCredentialStatus).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve({ configured: true, storage: "secret_service", sessionOnly: false, secretServiceAvailable: true, warning: null })); await settle();
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    renderPanel("en-US", props); await click("Delete credentials");
    expect(confirm).toHaveBeenLastCalledWith("Delete credentials for this hosted AI service?");
    renderPanel("zh-CN", props); await click("删除凭据");
    expect(confirm).toHaveBeenLastCalledWith("删除此托管 AI 服务的凭据？");
    expect(gateway.deleteAiCredential).not.toHaveBeenCalled();
  });

  it("keeps the frozen request and form state through a pending plan, then renders an expired plan and raw warning literally", async () => {
    const pending = deferred<TextTranslationPlan>(); const gateway = panelGateway({ planTextTranslation: vi.fn(() => pending.promise) });
    const props: RssTranslationPanelProps = { articleId: "a", articleText: "Article 设置 {count}", selectionText: "Selection 设置 {count}", gateway };
    renderPanel("zh-CN", props);
    const selects = host.querySelectorAll<HTMLSelectElement>("select"); await select(selects[0], "selection");
    const endpoint = host.querySelector<HTMLInputElement>(".rss-translation-wide input")!; await input(endpoint, "http://127.0.0.1:5999");
    await click("生成翻译计划"); renderPanel("en-US", props); renderPanel("zh-CN", props);
    expect(endpoint.value).toBe("http://127.0.0.1:5999"); expect(selects[0].value).toBe("selection"); expect(gateway.planTextTranslation).toHaveBeenCalledTimes(1);
    expect(gateway.planTextTranslation).toHaveBeenCalledWith(expect.objectContaining({ endpoint: "http://127.0.0.1:5999", text: "Selection 设置 {count}" }));
    const knownWarning = "After confirmation, text is sent only to the configured loopback LibreTranslate endpoint.";
    const extendedWarning = `${knownWarning} RAW_MARKER 设置 {count}`;
    await act(async () => pending.resolve(plan({ endpoint: "http://127.0.0.1:5999", sourceLanguage: "日本語", expiresAt: new Date(Date.now() - 1_000).toISOString(), warnings: ["设置", knownWarning, extendedWarning] }))); await settle();
    renderPanel("en-US", props);
    expect(host.textContent).toContain("This plan is no longer valid."); expect(host.textContent).toContain("设置"); expect(host.textContent).not.toContain("Settings"); expect(host.textContent).toContain("日本語 → Simplified Chinese");
    expect(host.textContent).toContain("After confirmation, the body will be sent only to the configured local LibreTranslate loopback address.");
    expect(host.textContent).toContain(extendedWarning);
    expect(host.querySelector<HTMLButtonElement>(".rss-translation-confirm")?.disabled).toBe(true);
  });

  it("does not duplicate a pending execution and rerenders its delayed local completion while publishing the same cache result", async () => {
    const pending = deferred<TextTranslationResult>(); const cache = new TranslationSessionCache(); const publish = vi.fn();
    const gateway = panelGateway({ executeTextTranslation: vi.fn(() => pending.promise) });
    const props: RssTranslationPanelProps = { articleId: "a", articleText: "Article source", selectionText: "", gateway, sessionCache: cache, onArticleTranslationChange: publish };
    renderPanel("zh-CN", props); await click("生成翻译计划"); await click("确认并翻译");
    renderPanel("en-US", props); renderPanel("zh-CN", props);
    expect(gateway.executeTextTranslation).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(translationResult())); await settle();
    renderPanel("en-US", props); expect(host.textContent).toContain("Translation complete."); expect(host.textContent).toContain("译文 设置 {count}");
    renderPanel("zh-CN", props); expect(host.textContent).toContain("翻译完成。"); expect(gateway.executeTextTranslation).toHaveBeenCalledTimes(1); expect(publish).toHaveBeenCalledWith(expect.objectContaining({ translatedText: "译文 设置 {count}" }), expect.any(String));
  });

  it("keeps one pending offline-cache read across a language round trip and publishes its literal result", async () => {
    const pending = deferred<Awaited<ReturnType<NonNullable<RssTranslationPanelProps["offlineTranslationGateway"]>["getOfflineTranslation"]>>>();
    const offline = { getOfflineTranslation: vi.fn(() => pending.promise), saveOfflineTranslation: vi.fn(), deleteOfflineTranslation: vi.fn() };
    const publish = vi.fn(); const props: RssTranslationPanelProps = { articleId: "a", articleText: "Article source", selectionText: "", offlineTranslationEnabled: true, offlineTranslationGateway: offline, onArticleTranslationChange: publish };
    renderPanel("zh-CN", props); renderPanel("en-US", props); expect(offline.getOfflineTranslation).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve({ ...translationResult(), articleId: "a", createdAt: 1, expiresAt: 2, byteSize: 10 })); await settle();
    expect(host.textContent).toContain("Translation restored from the offline translation cache."); expect(host.textContent).toContain("译文 设置 {count}");
    renderPanel("zh-CN", props); expect(host.textContent).toContain("已从离线译文缓存恢复"); expect(offline.getOfflineTranslation).toHaveBeenCalledTimes(1); expect(publish).toHaveBeenCalled();
  });

  it("keeps batch preparation single-shot and separates local item errors from identical raw backend errors", async () => {
    const pendingPlan = deferred<TextTranslationPlan>(); const rss = batchRss(["local", "raw", "planned"]);
    vi.mocked(rss.getArticle).mockImplementation(async (id: string) => {
      if (id === "local") return null;
      if (id === "raw") throw new Error("文章已不可用");
      return article(id);
    });
    const gateway = batchGateway({ planTextTranslation: vi.fn(() => pendingPlan.promise) });
    const props: RssBatchTranslationDialogProps = { open: true, onClose: vi.fn(), feeds: [feed], rssGateway: rss, translationGateway: gateway, sessionCache: new TranslationSessionCache() };
    renderBatch("zh-CN", props); await click("准备计划"); renderBatch("en-US", props); renderBatch("zh-CN", props);
    expect(rss.listArticles).toHaveBeenCalledTimes(1); expect(gateway.planTextTranslation).toHaveBeenCalledTimes(1);
    await act(async () => pendingPlan.resolve(plan({ warnings: ["设置"] }))); await settle(); renderBatch("en-US", props);
    expect(host.textContent).toContain("The article is no longer available");
    expect(host.textContent).toContain("文章已不可用");
    expect(host.textContent).toContain("Plan notice: 设置"); expect(host.textContent).not.toContain("Settings"); expect(host.textContent).toContain(feed.title);
  });

  it("preserves pause and minimized queue state without sending another batch item after a locale change", async () => {
    const first = deferred<TextTranslationResult>(); const gateway = batchGateway({ executeTextTranslation: vi.fn().mockImplementationOnce(() => first.promise).mockResolvedValue(translationResult("second")) });
    const props: RssBatchTranslationDialogProps = { open: true, onOpen: vi.fn(), onClose: vi.fn(), feeds: [feed], rssGateway: batchRss(), translationGateway: gateway, sessionCache: new TranslationSessionCache() };
    renderBatch("zh-CN", props); await select(host.querySelectorAll<HTMLSelectElement>(".rss-batch-translation-controls select")[2], "1"); await click("准备计划"); await click("确认并开始"); await click("暂停");
    renderBatch("en-US", props); await click("Minimize batch pretranslation");
    expect(host.textContent).toContain("Batch pretranslation: Pausing (2)"); expect(gateway.executeTextTranslation).toHaveBeenCalledTimes(1);
    renderBatch("zh-CN", props); expect(host.textContent).toContain("批量预翻译：暂停中（2）");
    await act(async () => first.resolve(translationResult("first"))); await settle();
    expect(gateway.executeTextTranslation).toHaveBeenCalledTimes(1); expect(host.textContent).toContain("批量预翻译：已暂停（2）");
  });

  it("uses the session cache without planning and keeps raw translated fields through language changes", async () => {
    const cache = new TranslationSessionCache(); const request: PlanTextTranslationRequest = { provider: "libretranslate_local", endpoint: "http://127.0.0.1:5000", model: "", sourceLanguage: "auto", targetLanguage: "zh", glossary: [], text: "Body a" };
    cache.set(buildTranslationSessionCacheKey({ articleId: "a", scope: "article", request }), translationResult());
    const gateway = batchGateway(); const props: RssBatchTranslationDialogProps = { open: true, onClose: vi.fn(), feeds: [feed], rssGateway: batchRss(["a"]), translationGateway: gateway, sessionCache: cache };
    renderBatch("zh-CN", props); await click("准备计划"); renderBatch("en-US", props);
    expect(host.textContent).toContain("Cached 1"); expect(host.textContent).toContain("标题 a {count}"); expect(gateway.planTextTranslation).not.toHaveBeenCalled(); expect(gateway.executeTextTranslation).not.toHaveBeenCalled();
  });
});
