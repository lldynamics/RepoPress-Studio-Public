import type { TextTranslationProvider } from "../../contracts/repository";

export const TRANSLATION_FEED_POLICIES_STORAGE_KEY = "repopress.rss.translation.feed-policies.v1";
export const TRANSLATION_GLOSSARY_STORAGE_KEY = "repopress.rss.translation.glossary.v1";

export type TranslationStrategy = "manual" | "local_first" | "ai_first";

export interface TranslationGlossaryEntry {
  source: string;
  target: string;
}

export interface TranslationFeedPolicy {
  provider: TextTranslationProvider;
  endpoint: string;
  model: string;
  sourceLanguage: string;
  targetLanguage: string;
  strategy: TranslationStrategy;
}

export interface ParsedTranslationGlossary {
  entries: TranslationGlossaryEntry[];
  invalidLines: number[];
}

const MAX_GLOSSARY_ENTRIES = 64;
const MAX_GLOSSARY_TERM_LENGTH = 160;
const MAX_FEED_ID_LENGTH = 128;
const MAX_ENDPOINT_LENGTH = 2_000;
const MAX_MODEL_LENGTH = 160;
const MAX_LANGUAGE_LENGTH = 32;
const PROVIDERS: readonly TextTranslationProvider[] = ["libretranslate_local", "ollama_local", "openai_compatible"];
const STRATEGIES: readonly TranslationStrategy[] = ["manual", "local_first", "ai_first"];
const LANGUAGES = new Set(["auto", "zh", "zt", "en", "ja", "ko"]);

function unicodeTrim(value: string, limit: number): string {
  return [...value.trim()].slice(0, limit).join("");
}

function glossaryEntry(value: unknown): TranslationGlossaryEntry | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<TranslationGlossaryEntry>;
  if (typeof candidate.source !== "string" || typeof candidate.target !== "string") return null;
  const source = unicodeTrim(candidate.source, MAX_GLOSSARY_TERM_LENGTH);
  const target = unicodeTrim(candidate.target, MAX_GLOSSARY_TERM_LENGTH);
  return source && target ? { source, target } : null;
}

export function normalizeTranslationGlossary(value: unknown): TranslationGlossaryEntry[] {
  if (!Array.isArray(value)) return [];
  const entries = new Map<string, TranslationGlossaryEntry>();
  for (const item of value) {
    const entry = glossaryEntry(item);
    if (!entry) continue;
    entries.set(entry.source, entry);
  }
  return [...entries.values()].slice(0, MAX_GLOSSARY_ENTRIES);
}

export function parseTranslationGlossary(text: string): ParsedTranslationGlossary {
  const invalidLines: number[] = [];
  const parsed: TranslationGlossaryEntry[] = [];
  if (typeof text !== "string") return { entries: [], invalidLines };
  text.split(/\r?\n/).forEach((line, index) => {
    const lineNumber = index + 1;
    const trimmed = line.trim();
    if (!trimmed) return;
    const tab = trimmed.indexOf("\t");
    const equals = trimmed.indexOf("=");
    const delimiter = tab >= 0 ? "\t" : equals >= 0 ? "=" : null;
    if (!delimiter) {
      invalidLines.push(lineNumber);
      return;
    }
    const at = trimmed.indexOf(delimiter);
    const entry = glossaryEntry({ source: trimmed.slice(0, at), target: trimmed.slice(at + 1) });
    if (!entry) invalidLines.push(lineNumber);
    else parsed.push(entry);
  });
  return { entries: normalizeTranslationGlossary(parsed), invalidLines };
}

export function stringifyTranslationGlossary(value: unknown): string {
  return normalizeTranslationGlossary(value).map(({ source, target }) => `${source}=${target}`).join("\n");
}

function safeFeedId(value: string): boolean {
  return value.length > 0 && value.length <= MAX_FEED_ID_LENGTH && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)
    && value !== "__proto__" && value !== "constructor" && value !== "prototype";
}

function language(value: unknown, allowAuto = true): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  if (normalized.length === 0 || normalized.length > MAX_LANGUAGE_LENGTH) return null;
  if (LANGUAGES.has(normalized) && (allowAuto || normalized !== "auto")) return normalized;
  return null;
}

function policy(value: unknown): TranslationFeedPolicy | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<TranslationFeedPolicy>;
  if (!PROVIDERS.includes(candidate.provider as TextTranslationProvider)) return null;
  if (!STRATEGIES.includes(candidate.strategy as TranslationStrategy)) return null;
  if (typeof candidate.endpoint !== "string" || !candidate.endpoint.trim()) return null;
  if (typeof candidate.model !== "string") return null;
  const sourceLanguage = language(candidate.sourceLanguage);
  const targetLanguage = language(candidate.targetLanguage, false);
  if (!sourceLanguage || !targetLanguage) return null;
  return {
    provider: candidate.provider as TextTranslationProvider,
    endpoint: candidate.endpoint.trim().slice(0, MAX_ENDPOINT_LENGTH),
    model: candidate.model.trim().slice(0, MAX_MODEL_LENGTH),
    sourceLanguage,
    targetLanguage,
    strategy: candidate.strategy as TranslationStrategy,
  };
}

export function normalizeFeedTranslationPolicies(value: unknown): Record<string, TranslationFeedPolicy> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const result: Record<string, TranslationFeedPolicy> = {};
  for (const [feedId, candidate] of Object.entries(value)) {
    if (!safeFeedId(feedId)) continue;
    const normalized = policy(candidate);
    if (normalized) result[feedId] = normalized;
  }
  return result;
}

export function providerOrderForStrategy(strategy: TranslationStrategy): TextTranslationProvider[] {
  switch (strategy) {
    case "local_first": return ["libretranslate_local", "ollama_local", "openai_compatible"];
    case "ai_first": return ["openai_compatible", "ollama_local", "libretranslate_local"];
    case "manual": return [];
  }
}

export function nextTranslationProvider(current: TextTranslationProvider | null | undefined, strategy: TranslationStrategy): TextTranslationProvider | null {
  const order = providerOrderForStrategy(strategy);
  if (!order.length) return null;
  const index = current == null ? -1 : order.indexOf(current);
  return order[index + 1] ?? null;
}
