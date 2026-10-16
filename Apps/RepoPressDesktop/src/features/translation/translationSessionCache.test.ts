import { describe, expect, it } from "vitest";
import type { PlanTextTranslationRequest, TextTranslationResult } from "../../contracts/repository";
import { buildTranslationSessionCacheKey, TranslationSessionCache } from "./translationSessionCache";

const request: PlanTextTranslationRequest = {
  provider: "ollama_local",
  endpoint: "http://127.0.0.1:11434/v1",
  model: "qwen3",
  sourceLanguage: "auto",
  targetLanguage: "zh",
  text: "Hello\n世界 😀",
};
const result: TextTranslationResult = {
  translatedText: "你好\n世界 😀",
  detectedSourceLanguage: "en",
  provider: "ollama_local",
  model: "qwen3",
  targetLanguage: "zh",
};
const key = (overrides: Partial<PlanTextTranslationRequest> = {}, scope: "article" | "selection" = "article") =>
  buildTranslationSessionCacheKey({ articleId: "article-1", scope, request: { ...request, ...overrides } });

describe("TranslationSessionCache key", () => {
  it("binds article, scope, every request field, Unicode, and newlines", () => {
    const base = key();
    expect(buildTranslationSessionCacheKey({ articleId: "article-2", scope: "article", request })).not.toBe(base);
    expect(key({}, "selection")).not.toBe(base);
    for (const field of ["provider", "endpoint", "model", "sourceLanguage", "targetLanguage", "text"] as const) {
      expect(key({ [field]: `${request[field]}-changed` })).not.toBe(base);
    }
    expect(base).toContain("\\n");
    expect(base).toContain("世界");
    expect(base).toContain("😀");
  });

  it("changes when the normalized glossary sent to the provider changes", () => {
    const base = key({ glossary: [{ source: "RepoPress", target: "仓库新闻" }] });
    expect(key({ glossary: [{ source: "RepoPress", target: "代码新闻" }] })).not.toBe(base);
    expect(key({ glossary: [] })).not.toBe(base);
  });

  it("does not collide when values contain separators or JSON-like text", () => {
    const first = buildTranslationSessionCacheKey({ articleId: "a|b", scope: "article", request: { ...request, text: "c" } });
    const second = buildTranslationSessionCacheKey({ articleId: "a", scope: "article", request: { ...request, text: "b|c" } });
    expect(first).not.toBe(second);
  });
});

describe("TranslationSessionCache", () => {
  it("returns null when empty and isolates stored result objects", () => {
    const cache = new TranslationSessionCache();
    expect(cache.get("missing")).toBeNull();
    const input = { ...result };
    cache.set("one", input);
    input.translatedText = "caller mutation";
    const returned = cache.get("one");
    expect(returned?.translatedText).toBe("你好\n世界 😀");
    if (returned) returned.translatedText = "returned mutation";
    expect(cache.get("one")?.translatedText).toBe("你好\n世界 😀");
  });

  it("touches entries on get and overwriting set", () => {
    const cache = new TranslationSessionCache(2);
    cache.set("a", result); cache.set("b", { ...result, translatedText: "B" });
    expect(cache.get("a")?.translatedText).toBe("你好\n世界 😀");
    cache.set("c", { ...result, translatedText: "C" });
    expect(cache.get("b")).toBeNull();
    expect(cache.get("a")).not.toBeNull();
    cache.set("a", { ...result, translatedText: "A2" });
    cache.set("d", { ...result, translatedText: "D" });
    expect(cache.get("c")).toBeNull();
    expect(cache.get("a")?.translatedText).toBe("A2");
  });

  it("evicts the least recently used entry and supports lifecycle operations", () => {
    const cache = new TranslationSessionCache(2);
    cache.set("a", result); cache.set("b", result); cache.set("c", result);
    expect(cache.size).toBe(2);
    expect(cache.delete("b")).toBe(true);
    expect(cache.delete("b")).toBe(false);
    cache.clear();
    expect(cache.size).toBe(0);
  });

  it("rejects invalid limits", () => {
    expect(() => new TranslationSessionCache(0)).toThrow(RangeError);
    expect(() => new TranslationSessionCache(-1)).toThrow(RangeError);
    expect(() => new TranslationSessionCache(1.5)).toThrow(RangeError);
    expect(() => new TranslationSessionCache(Number.NaN)).toThrow(RangeError);
  });
});
