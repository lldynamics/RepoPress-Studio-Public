import type { PlanTextTranslationRequest, TextTranslationResult } from "../../contracts/repository";

export type RssTranslationScope = "article" | "selection";

type TranslationCacheKeyInput = {
  articleId: string;
  scope: RssTranslationScope;
  request: PlanTextTranslationRequest;
};

/**
 * Builds a collision-safe, deterministic key from every value that affects a
 * translation request. JSON encoding keeps delimiters and Unicode text
 * unambiguous. The resulting key remains only in this process-local cache.
 */
export function buildTranslationSessionCacheKey(input: TranslationCacheKeyInput): string {
  return JSON.stringify([
    "repopress-rss-translation-session-v1",
    input.articleId,
    input.scope,
    input.request.provider,
    input.request.endpoint,
    input.request.model,
    input.request.sourceLanguage,
    input.request.targetLanguage,
    input.request.glossary ?? [],
    input.request.text,
  ]);
}

function copyResult(result: TextTranslationResult): TextTranslationResult {
  return { ...result };
}

export class TranslationSessionCache {
  private readonly entries = new Map<string, TextTranslationResult>();

  constructor(private readonly maxEntries = 32) {
    if (!Number.isInteger(maxEntries) || maxEntries <= 0) {
      throw new RangeError("Translation session cache limit must be a positive integer.");
    }
  }

  get(key: string): TextTranslationResult | null {
    const result = this.entries.get(key);
    if (!result) return null;
    this.entries.delete(key);
    this.entries.set(key, result);
    return copyResult(result);
  }

  set(key: string, result: TextTranslationResult): void {
    this.entries.delete(key);
    this.entries.set(key, copyResult(result));
    while (this.entries.size > this.maxEntries) {
      const oldest = this.entries.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }

  delete(key: string): boolean {
    return this.entries.delete(key);
  }

  clear(): void {
    this.entries.clear();
  }

  get size(): number {
    return this.entries.size;
  }
}
