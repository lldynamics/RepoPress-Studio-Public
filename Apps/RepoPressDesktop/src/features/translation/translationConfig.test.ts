import { describe, expect, it } from "vitest";
import { DEFAULT_TRANSLATION_CONFIG, defaultsForTranslationProvider, normalizeTranslationConfig, textByteSize, translationNeedsModel } from "./translationConfig";

describe("RSS translation config", () => {
  it("uses safe provider defaults and only requires a model for AI providers", () => {
    expect(DEFAULT_TRANSLATION_CONFIG).toMatchObject({ provider: "libretranslate_local", endpoint: "http://127.0.0.1:5000", targetLanguage: "zh" });
    expect(defaultsForTranslationProvider("ollama_local").endpoint).toBe("http://127.0.0.1:11434/v1");
    expect(defaultsForTranslationProvider("openai_compatible").endpoint).toBe("https://api.openai.com/v1");
    expect(translationNeedsModel("libretranslate_local")).toBe(false);
    expect(translationNeedsModel("ollama_local")).toBe(true);
  });

  it("drops malformed saved settings and never contains a token", () => {
    expect(normalizeTranslationConfig({ provider: "not-a-provider", endpoint: 7, model: null, token: "secret" })).toEqual(DEFAULT_TRANSLATION_CONFIG);
    expect(normalizeTranslationConfig({ provider: "openai_compatible", endpoint: " https://example.test/v1 ", model: " gpt-test ", targetLanguage: "ja" })).toEqual({ provider: "openai_compatible", endpoint: "https://example.test/v1", model: "gpt-test", sourceLanguage: "auto", targetLanguage: "ja", strategy: "manual" });
  });

  it("measures UTF-8 bytes for the same limit used by the backend", () => {
    expect(textByteSize("abc")).toBe(3);
    expect(textByteSize("中文")).toBe(6);
  });
});
