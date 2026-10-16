import { describe, expect, it } from "vitest";
import {
  TRANSLATION_FEED_POLICIES_STORAGE_KEY,
  TRANSLATION_GLOSSARY_STORAGE_KEY,
  nextTranslationProvider,
  normalizeFeedTranslationPolicies,
  normalizeTranslationGlossary,
  parseTranslationGlossary,
  providerOrderForStrategy,
  stringifyTranslationGlossary,
} from "./translationQuality";

describe("translation quality data", () => {
  it("exports stable storage keys", () => {
    expect(TRANSLATION_FEED_POLICIES_STORAGE_KEY).toContain("translation");
    expect(TRANSLATION_GLOSSARY_STORAGE_KEY).toContain("glossary");
  });

  it("normalizes, bounds, and last-write-wins glossary terms", () => {
    const long = "😀".repeat(200);
    expect(normalizeTranslationGlossary([
      { source: " hello ", target: " 你好 " },
      { source: "hello", target: "您好" },
      { source: "", target: "x" },
      { source: "x", target: "" },
      { source: "bad" },
      { source: "emoji", target: long },
    ])).toEqual([{ source: "hello", target: "您好" }, { source: "emoji", target: "😀".repeat(160) }]);
    expect(normalizeTranslationGlossary(Array.from({ length: 70 }, (_, i) => ({ source: `s${i}`, target: `t${i}` })))).toHaveLength(64);
  });

  it("parses equals and tab records and reports malformed line numbers", () => {
    expect(parseTranslationGlossary(" apple = 苹果\n\nhello\t你好\ninvalid\n=empty\nlast=value=with=equals")).toEqual({
      entries: [
        { source: "apple", target: "苹果" },
        { source: "hello", target: "你好" },
        { source: "last", target: "value=with=equals" },
      ],
      invalidLines: [4, 5],
    });
    expect(stringifyTranslationGlossary([{ source: " a ", target: " b " }, { source: "a", target: "c" }])).toBe("a=c");
  });

  it("accepts safe policies and ignores malformed or hostile records", () => {
    const valid = { provider: "ollama_local", endpoint: " http://127.0.0.1:11434/v1 ", model: " qwen ", sourceLanguage: "auto", targetLanguage: "zh", strategy: "local_first" };
    expect(normalizeFeedTranslationPolicies({ feed_1: valid, "../escape": valid, __proto__: valid, bad: { ...valid, provider: "evil" }, too: { ...valid, targetLanguage: "javascript:alert(1)" } })).toEqual({
      feed_1: { ...valid, endpoint: "http://127.0.0.1:11434/v1", model: "qwen" },
    });
    expect(normalizeFeedTranslationPolicies(null)).toEqual({});
  });

  it("provides deterministic fallback order", () => {
    expect(providerOrderForStrategy("manual")).toEqual([]);
    expect(providerOrderForStrategy("local_first")).toEqual(["libretranslate_local", "ollama_local", "openai_compatible"]);
    expect(providerOrderForStrategy("ai_first")).toEqual(["openai_compatible", "ollama_local", "libretranslate_local"]);
    expect(nextTranslationProvider(null, "local_first")).toBe("libretranslate_local");
    expect(nextTranslationProvider("libretranslate_local", "local_first")).toBe("ollama_local");
    expect(nextTranslationProvider("openai_compatible", "local_first")).toBeNull();
    expect(nextTranslationProvider("ollama_local", "manual")).toBeNull();
  });
});
