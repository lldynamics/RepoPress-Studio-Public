import type { TextTranslationProvider } from "../../contracts/repository";
import type { TranslationStrategy } from "./translationQuality";

export const TRANSLATION_CONFIG_STORAGE_KEY = "repopress.rss.translation.config.v1";

export interface TranslationConfig {
  provider: TextTranslationProvider;
  endpoint: string;
  model: string;
  sourceLanguage: string;
  targetLanguage: string;
  strategy: TranslationStrategy;
}

export const DEFAULT_TRANSLATION_CONFIG: TranslationConfig = {
  provider: "libretranslate_local",
  endpoint: "http://127.0.0.1:5000",
  model: "",
  sourceLanguage: "auto",
  targetLanguage: "zh",
  strategy: "manual",
};

export function defaultsForTranslationProvider(provider: TextTranslationProvider): Pick<TranslationConfig, "endpoint" | "model"> {
  switch (provider) {
    case "libretranslate_local": return { endpoint: "http://127.0.0.1:5000", model: "" };
    case "ollama_local": return { endpoint: "http://127.0.0.1:11434/v1", model: "" };
    case "openai_compatible": return { endpoint: "https://api.openai.com/v1", model: "" };
  }
}

export function normalizeTranslationConfig(value: unknown): TranslationConfig {
  if (!value || typeof value !== "object") return DEFAULT_TRANSLATION_CONFIG;
  const candidate = value as Partial<TranslationConfig>;
  const provider = candidate.provider === "libretranslate_local" || candidate.provider === "ollama_local" || candidate.provider === "openai_compatible"
    ? candidate.provider : DEFAULT_TRANSLATION_CONFIG.provider;
  const defaults = defaultsForTranslationProvider(provider);
  return {
    provider,
    endpoint: typeof candidate.endpoint === "string" && candidate.endpoint.trim() ? candidate.endpoint.trim().slice(0, 2_000) : defaults.endpoint,
    model: typeof candidate.model === "string" ? candidate.model.trim().slice(0, 160) : defaults.model,
    sourceLanguage: candidate.sourceLanguage === "zh" || candidate.sourceLanguage === "zt" || candidate.sourceLanguage === "en" || candidate.sourceLanguage === "ja" || candidate.sourceLanguage === "ko" || candidate.sourceLanguage === "auto" ? candidate.sourceLanguage : DEFAULT_TRANSLATION_CONFIG.sourceLanguage,
    targetLanguage: candidate.targetLanguage === "zt" || candidate.targetLanguage === "en" || candidate.targetLanguage === "ja" || candidate.targetLanguage === "ko" || candidate.targetLanguage === "zh" ? candidate.targetLanguage : DEFAULT_TRANSLATION_CONFIG.targetLanguage,
    strategy: candidate.strategy === "local_first" || candidate.strategy === "ai_first" || candidate.strategy === "manual" ? candidate.strategy : DEFAULT_TRANSLATION_CONFIG.strategy,
  };
}

export function translationNeedsModel(provider: TextTranslationProvider): boolean {
  return provider !== "libretranslate_local";
}

export function textByteSize(value: string): number {
  return new Blob([value]).size;
}
