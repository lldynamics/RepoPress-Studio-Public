import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { PlanTextTranslationRequest, TextTranslationResult } from "../../contracts/repository";
import { RssTranslationPanel, type RssTranslationResultChange } from "./RssTranslationPanel";
import { buildTranslationSessionCacheKey, TranslationSessionCache } from "./translationSessionCache";

const articleId = "article-structured";
const articleText = "First paragraph.\n\nSecond paragraph.";
const request = (text: string): PlanTextTranslationRequest => ({
  provider: "libretranslate_local",
  endpoint: "http://127.0.0.1:5000",
  model: "",
  sourceLanguage: "auto",
  targetLanguage: "zh",
  text,
});
const result = (translatedText: string): TextTranslationResult => ({
  translatedText,
  detectedSourceLanguage: "en",
  provider: "libretranslate_local",
  model: "",
  targetLanguage: "zh",
});

let root: Root | null = null;
let container: HTMLDivElement | null = null;

afterEach(() => {
  if (root) act(() => root?.unmount());
  root = null;
  container?.remove();
  container = null;
  localStorage.clear();
});

function mount(props: Parameters<typeof RssTranslationPanel>[0]) {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  act(() => root?.render(createElement(RssTranslationPanel, props)));
}

function gateway(overrides: Partial<Parameters<typeof RssTranslationPanel>[0]["gateway"]> = {}) {
  return {
    planTextTranslation: vi.fn().mockResolvedValue({ planId: "plan-1", provider: "libretranslate_local", endpoint: "http://127.0.0.1:5000", model: "", sourceLanguage: "auto", targetLanguage: "zh", textBytes: 16, glossaryCount: 0, expiresAt: new Date(Date.now() + 60_000).toISOString(), summary: "test", warnings: [] }),
    executeTextTranslation: vi.fn().mockResolvedValue(result("译文")),
    aiCredentialStatus: vi.fn(),
    storeAiCredential: vi.fn(),
    deleteAiCredential: vi.fn(),
    ...overrides,
  } as NonNullable<Parameters<typeof RssTranslationPanel>[0]["gateway"]>;
}

async function change(element: HTMLSelectElement | HTMLTextAreaElement, value: string) {
  await act(async () => {
    element.value = value;
    element.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

async function click(button: HTMLButtonElement) {
  await act(async () => {
    button.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await Promise.resolve();
  });
}

async function flush() {
  await act(async () => { await new Promise((resolve) => window.setTimeout(resolve, 0)); });
}

function setTextAreaValue(element: HTMLTextAreaElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")?.set?.call(element, value);
}

describe("RSS translation panel result publication", () => {
  it("hydrates and manages persistent cache only for the exact whole-article request", async () => {
    const offline = { getOfflineTranslation: vi.fn().mockResolvedValue({ ...result("离线译文"), articleId, createdAt: 0, expiresAt: 1, byteSize: 12 }), saveOfflineTranslation: vi.fn().mockResolvedValue({}), deleteOfflineTranslation: vi.fn().mockResolvedValue(undefined) };
    const service = gateway();
    mount({ articleId, articleText, selectionText: "选区", gateway: service, offlineTranslationGateway: offline as never, offlineTranslationEnabled: true });
    await flush();
    expect(offline.getOfflineTranslation).toHaveBeenCalledWith(expect.objectContaining({ articleId, request: expect.objectContaining({ text: articleText }) }));
    expect(container?.querySelector<HTMLTextAreaElement>('textarea[aria-label="只读译文"]')?.value).toBe("离线译文");
    await click([...container!.querySelectorAll<HTMLButtonElement>(".rss-translation-result button")].find((button) => button.textContent === "清除此译文")!);
    expect(offline.deleteOfflineTranslation).toHaveBeenCalledWith(expect.objectContaining({ articleId, request: expect.objectContaining({ text: articleText }) }));

    act(() => root?.render(createElement(RssTranslationPanel, { articleId, articleText, selectionText: "选区", gateway: service, offlineTranslationGateway: offline as never, offlineTranslationEnabled: true })));
    const scope = container!.querySelector<HTMLSelectElement>("select")!;
    await change(scope, "selection"); await flush();
    expect(offline.getOfflineTranslation).toHaveBeenCalledTimes(1);
    expect(offline.saveOfflineTranslation).not.toHaveBeenCalled();
  });

  it("persists a confirmed whole-article result but never a selection", async () => {
    const offline = { getOfflineTranslation: vi.fn().mockResolvedValue(null), saveOfflineTranslation: vi.fn().mockResolvedValue({}), deleteOfflineTranslation: vi.fn().mockResolvedValue(undefined) };
    const service = gateway();
    mount({ articleId, articleText, selectionText: "选区", gateway: service, offlineTranslationGateway: offline as never, offlineTranslationEnabled: true });
    await flush();
    await click([...container!.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "生成翻译计划")!);
    await click(container!.querySelector<HTMLButtonElement>(".rss-translation-confirm")!); await flush();
    expect(offline.saveOfflineTranslation).toHaveBeenCalledWith(expect.objectContaining({ articleId, request: expect.objectContaining({ text: articleText }) }));
  });

  it("plans and executes title plus HTML text nodes without exposing the cache envelope", async () => {
    const planStructuredTextTranslation = vi.fn().mockResolvedValue({
      planId: "structured-plan-1",
      provider: "libretranslate_local",
      endpoint: "http://127.0.0.1:5000",
      model: "",
      sourceLanguage: "auto",
      targetLanguage: "zh",
      textBytes: 25,
      segmentCount: 4,
      glossaryCount: 0,
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
      summary: "test structured plan",
      warnings: [],
    });
    const executeStructuredTextTranslation = vi.fn().mockResolvedValue({
      translations: [
        { id: "title", translatedText: "标题" },
        { id: "body.0", translatedText: "你好 " },
        { id: "body.1", translatedText: "世界" },
        { id: "body.2", translatedText: "。" },
      ],
      detectedSourceLanguage: "en",
      provider: "libretranslate_local",
      model: "",
      targetLanguage: "zh",
    });
    const articleChanges = vi.fn();
    const service = gateway({ planStructuredTextTranslation, executeStructuredTextTranslation });

    mount({
      articleId,
      articleTitle: "Title",
      articleHtml: "<p>Hello <a href='https://example.test'>world</a>.</p><pre>const x = 1;</pre>",
      articleText,
      selectionText: "",
      gateway: service,
      onArticleTranslationChange: articleChanges,
    });
    await click([...container!.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "生成翻译计划")!);
    await click(container!.querySelector<HTMLButtonElement>(".rss-translation-confirm")!);
    await flush();

    expect(planStructuredTextTranslation).toHaveBeenCalledWith(expect.objectContaining({
      segments: [
        { id: "title", text: "Title" },
        { id: "body.0", text: "Hello " },
        { id: "body.1", text: "world" },
        { id: "body.2", text: "." },
      ],
    }));
    expect(executeStructuredTextTranslation).toHaveBeenCalledWith(expect.objectContaining({
      planId: "structured-plan-1",
      segments: expect.any(Array),
    }));
    expect(service.planTextTranslation).not.toHaveBeenCalled();
    expect(service.executeTextTranslation).not.toHaveBeenCalled();
    expect(container?.querySelector<HTMLTextAreaElement>('textarea[aria-label="只读译文"]')?.value).toBe("标题\n\n你好 \n\n世界\n\n。");
    const published = articleChanges.mock.calls[articleChanges.mock.calls.length - 1]?.[0] as TextTranslationResult;
    expect(published.translatedText).toMatch(/^repopress-structured-translation:v1:/);
    expect(published.translatedText).not.toContain("Hello");
  });

  it("publishes the complete article cache key with a cached result", () => {
    const cache = new TranslationSessionCache();
    const cacheKey = buildTranslationSessionCacheKey({ articleId, scope: "article", request: request(articleText) });
    const cached = result("第一段。\n\n第二段。");
    cache.set(cacheKey, cached);
    const articleChanges = vi.fn();
    const resultChanges = vi.fn<(change: RssTranslationResultChange) => void>();

    mount({ articleId, articleText, selectionText: "", sessionCache: cache, onArticleTranslationChange: articleChanges, onTranslationResultChange: resultChanges });

    expect(articleChanges).toHaveBeenCalledWith(cached, cacheKey);
    expect(resultChanges).toHaveBeenCalledWith({ scope: "article", sourceText: articleText, requestKey: cacheKey, result: cached });
  });

  it("publishes a batch-written article cache entry when its shared revision advances without planning or executing", () => {
    const cache = new TranslationSessionCache();
    const cacheKey = buildTranslationSessionCacheKey({ articleId, scope: "article", request: request(articleText) });
    const cached = result("批量译文");
    const service = gateway();
    const articleChanges = vi.fn();
    const resultChanges = vi.fn<(change: RssTranslationResultChange) => void>();
    const props = { articleId, articleText, selectionText: "", gateway: service, sessionCache: cache, cacheRevision: 0, onArticleTranslationChange: articleChanges, onTranslationResultChange: resultChanges };

    mount(props);
    articleChanges.mockClear();
    resultChanges.mockClear();
    cache.set(cacheKey, cached);
    act(() => root?.render(createElement(RssTranslationPanel, { ...props, cacheRevision: 1 })));

    expect(articleChanges).toHaveBeenCalledWith(cached, cacheKey);
    expect(resultChanges).toHaveBeenCalledWith({ scope: "article", sourceText: articleText, requestKey: cacheKey, result: cached });
    expect(service.planTextTranslation).not.toHaveBeenCalled();
    expect(service.executeTextTranslation).not.toHaveBeenCalled();
  });

  it("keeps a cached paragraph result in selection scope without a network gateway", () => {
    const paragraph = "Second paragraph.";
    const cache = new TranslationSessionCache();
    const cacheKey = buildTranslationSessionCacheKey({ articleId, scope: "selection", request: request(paragraph) });
    const cached = result("第二段。");
    cache.set(cacheKey, cached);
    const resultChanges = vi.fn<(change: RssTranslationResultChange) => void>();

    mount({ articleId, articleText, selectionText: paragraph, sessionCache: cache, onTranslationResultChange: resultChanges });
    const scope = container?.querySelector("select");
    expect(scope).not.toBeNull();
    act(() => {
      if (!scope) return;
      scope.value = "selection";
      scope.dispatchEvent(new Event("change", { bubbles: true }));
    });

    expect(resultChanges).toHaveBeenCalledWith({ scope: "selection", sourceText: paragraph, requestKey: cacheKey, result: cached });
    expect(container?.querySelector<HTMLTextAreaElement>('textarea[aria-label="只读译文"]')?.value).toBe("第二段。");
  });

  it("sends the selected source language and normalized global glossary in the plan request", async () => {
    const service = gateway();
    mount({ articleId, articleText, selectionText: "", gateway: service });
    const selects = container?.querySelectorAll<HTMLSelectElement>("select");
    const glossary = container?.querySelector<HTMLTextAreaElement>('section[aria-label="全局术语表"] textarea');
    expect(selects).toHaveLength(5);
    expect(glossary).not.toBeNull();
    await change(selects![3], "ja");
    await act(async () => {
      setTextAreaValue(glossary!, "RepoPress=仓库新闻\ninvalid");
      glossary!.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await flush();
    await click([...container!.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "生成翻译计划")!);
    expect(service.planTextTranslation).toHaveBeenCalledWith(expect.objectContaining({ sourceLanguage: "ja", glossary: [{ source: "RepoPress", target: "仓库新闻" }] }));
    expect(container?.textContent).toContain("无效术语行：2");
  });

  it("restores each feed policy without applying it to another feed", () => {
    localStorage.setItem("repopress.rss.translation.feed-policies.v1", JSON.stringify({
      "feed-a": { provider: "openai_compatible", endpoint: "https://api.openai.com/v1", model: "gpt-test", sourceLanguage: "ja", targetLanguage: "zh", strategy: "ai_first" },
      "feed-b": { provider: "libretranslate_local", endpoint: "http://127.0.0.1:5000", model: "", sourceLanguage: "en", targetLanguage: "ko", strategy: "local_first" },
    }));
    mount({ articleId, articleText, selectionText: "", feedId: "feed-a", feedTitle: "A" });
    let selects = container?.querySelectorAll<HTMLSelectElement>("select");
    expect(selects?.[1].value).toBe("ai_first");
    expect(selects?.[3].value).toBe("ja");
    expect(selects?.[4].value).toBe("zh");
    act(() => root?.render(createElement(RssTranslationPanel, { articleId, articleText, selectionText: "", feedId: "feed-b", feedTitle: "B" })));
    selects = container?.querySelectorAll<HTMLSelectElement>("select");
    expect(selects?.[1].value).toBe("local_first");
    expect(selects?.[3].value).toBe("en");
    expect(selects?.[4].value).toBe("ko");
  });

  it("remembers the active automatic strategy when enabling a feed policy", async () => {
    mount({ articleId, articleText, selectionText: "", feedId: "feed-a", feedTitle: "A" });
    const selects = container?.querySelectorAll<HTMLSelectElement>("select");
    await change(selects![1], "ai_first");
    const rememberFeed = container!.querySelector<HTMLInputElement>(".rss-translation-feed-policy input")!;
    await act(async () => {
      rememberFeed.click();
    });
    await flush();

    const policies = JSON.parse(localStorage.getItem("repopress.rss.translation.feed-policies.v1") ?? "{}") as Record<string, { strategy?: string; provider?: string }>;
    expect(policies["feed-a"]).toMatchObject({ strategy: "ai_first", provider: "openai_compatible" });
  });

  it("does not try a fallback automatically and clears the plan when switching providers", async () => {
    const executeTextTranslation = vi.fn().mockRejectedValue(new Error("offline"));
    const service = gateway({ executeTextTranslation });
    mount({ articleId, articleText, selectionText: "", gateway: service, feedId: "feed-a" });
    const selects = container?.querySelectorAll<HTMLSelectElement>("select");
    await change(selects![1], "local_first");
    await click([...container!.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "生成翻译计划")!);
    await click(container!.querySelector<HTMLButtonElement>(".rss-translation-confirm")!);
    await flush();
    expect(executeTextTranslation).toHaveBeenCalledTimes(1);
    expect(service.planTextTranslation).toHaveBeenCalledTimes(1);
    const fallback = [...container!.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent?.includes("切换到后备方案"));
    expect(fallback).toBeTruthy();
    await click(fallback!);
    expect(executeTextTranslation).toHaveBeenCalledTimes(1);
    expect(service.planTextTranslation).toHaveBeenCalledTimes(1);
    expect(container?.querySelector(".rss-translation-plan")).toBeNull();
  });
});
