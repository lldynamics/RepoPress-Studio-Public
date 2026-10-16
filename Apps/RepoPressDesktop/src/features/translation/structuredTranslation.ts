/** A source paragraph and its optionally aligned translation. */
export interface RssTranslationParagraph {
  id: string;
  sourceText: string;
  translatedText: string | null;
  position: number;
}

export interface RssStructuredTranslation {
  paragraphs: RssTranslationParagraph[];
  unmatchedTranslations: string[];
  exactAlignment: boolean;
}

function normalizedNewlines(text: string): string {
  return text.replace(/\r\n?/g, "\n");
}

/** Split model output conservatively, preferring the paragraph delimiter. */
export function splitTranslationParagraphs(text: string): string[] {
  const normalized = normalizedNewlines(text).trim();
  if (!normalized) return [];
  const blocks = normalized.split(/\n\s*\n+/).map((part) => part.trim()).filter(Boolean);
  if (blocks.length > 1) return blocks;
  const lines = normalized.split("\n").map((line) => line.trim()).filter(Boolean);
  return lines.length > 1 ? lines : blocks;
}

// FNV-1a gives a small, stable identifier without relying on random or runtime state.
function stableParagraphId(position: number, sourceText: string): string {
  let hash = 2166136261;
  for (let index = 0; index < sourceText.length; index += 1) {
    hash ^= sourceText.charCodeAt(index);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return `paragraph-${position}-${hash.toString(16).padStart(8, "0")}`;
}

export function buildStructuredTranslation(
  sourceText: string,
  translatedText: string,
  overrides: Readonly<Record<string, string>> = {},
): RssStructuredTranslation {
  const source = splitTranslationParagraphs(sourceText);
  const translations = splitTranslationParagraphs(translatedText);
  const exactAlignment = source.length === translations.length;
  const paragraphs = source.map((sourceParagraph, position) => {
    const id = stableParagraphId(position, sourceParagraph);
    return {
      id,
      sourceText: sourceParagraph,
      translatedText: Object.prototype.hasOwnProperty.call(overrides, id)
        ? overrides[id] ?? null
        : translations[position] ?? null,
      position,
    };
  });
  return { paragraphs, unmatchedTranslations: translations.slice(source.length), exactAlignment };
}

export function structuredTranslationText(value: RssStructuredTranslation): string {
  return [...value.paragraphs.map((paragraph) => paragraph.translatedText ?? paragraph.sourceText), ...value.unmatchedTranslations]
    .join("\n\n");
}
