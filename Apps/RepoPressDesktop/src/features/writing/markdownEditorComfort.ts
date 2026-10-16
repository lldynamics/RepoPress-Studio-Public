export interface MarkdownEditorComfortOptions {
  /** Extra space, in pixels, added between editor lines. */
  lineSpacing: number;
  /** Maximum readable width for the Markdown body, in pixels. */
  bodyWidth: number;
  spellCheckEnabled: boolean;
  typewriterModeEnabled: boolean;
  currentParagraphHighlightEnabled: boolean;
  warmPaperBackgroundEnabled: boolean;
  paragraphSpotlightEnabled: boolean;
}

export interface MarkdownParagraphRange {
  from: number;
  to: number;
}

export interface MarkdownEditorComfortClassPlan {
  className?: string;
  style?: Record<"--rp-editor-line-spacing" | "--rp-editor-body-width", string>;
}

export const DEFAULT_MARKDOWN_EDITOR_COMFORT: MarkdownEditorComfortOptions = {
  lineSpacing: 4,
  bodyWidth: 820,
  spellCheckEnabled: false,
  typewriterModeEnabled: false,
  currentParagraphHighlightEnabled: false,
  warmPaperBackgroundEnabled: false,
  paragraphSpotlightEnabled: false,
};

const clampInteger = (value: unknown, minimum: number, maximum: number, fallback: number) =>
  typeof value === "number" && Number.isFinite(value)
    ? Math.min(maximum, Math.max(minimum, Math.round(value)))
    : fallback;

const normalizeBoolean = (value: unknown, fallback: boolean) =>
  typeof value === "boolean" ? value : fallback;

/**
 * Produces a complete, bounded preference object even when an older saved
 * preference record is partial or malformed.
 */
export function normalizeMarkdownEditorComfort(
  comfort?: Partial<MarkdownEditorComfortOptions>,
): MarkdownEditorComfortOptions {
  return {
    lineSpacing: clampInteger(comfort?.lineSpacing, 0, 12, DEFAULT_MARKDOWN_EDITOR_COMFORT.lineSpacing),
    bodyWidth: clampInteger(comfort?.bodyWidth, 560, 1200, DEFAULT_MARKDOWN_EDITOR_COMFORT.bodyWidth),
    spellCheckEnabled: normalizeBoolean(comfort?.spellCheckEnabled, DEFAULT_MARKDOWN_EDITOR_COMFORT.spellCheckEnabled),
    typewriterModeEnabled: normalizeBoolean(comfort?.typewriterModeEnabled, DEFAULT_MARKDOWN_EDITOR_COMFORT.typewriterModeEnabled),
    currentParagraphHighlightEnabled:
      normalizeBoolean(comfort?.currentParagraphHighlightEnabled, DEFAULT_MARKDOWN_EDITOR_COMFORT.currentParagraphHighlightEnabled),
    warmPaperBackgroundEnabled:
      normalizeBoolean(comfort?.warmPaperBackgroundEnabled, DEFAULT_MARKDOWN_EDITOR_COMFORT.warmPaperBackgroundEnabled),
    paragraphSpotlightEnabled:
      normalizeBoolean(comfort?.paragraphSpotlightEnabled, DEFAULT_MARKDOWN_EDITOR_COMFORT.paragraphSpotlightEnabled),
  };
}

/** Returns no attributes when comfort settings are absent, preserving legacy rendering exactly. */
export function planMarkdownEditorComfortClass(
  comfort?: Partial<MarkdownEditorComfortOptions>,
): MarkdownEditorComfortClassPlan {
  if (comfort === undefined) return {};

  const normalized = normalizeMarkdownEditorComfort(comfort);
  const classNames = ["rp-markdown-editor-comfort"];
  if (normalized.warmPaperBackgroundEnabled) classNames.push("rp-markdown-editor-warm-paper");
  if (normalized.typewriterModeEnabled) classNames.push("rp-markdown-editor-typewriter");
  if (normalized.paragraphSpotlightEnabled) classNames.push("rp-markdown-editor-paragraph-spotlight");

  return {
    className: classNames.join(" "),
    style: {
      "--rp-editor-line-spacing": `${normalized.lineSpacing}px`,
      "--rp-editor-body-width": `${normalized.bodyWidth}px`,
    },
  };
}

function lineStartBefore(document: string, position: number): number {
  return document.lastIndexOf("\n", position - 1) + 1;
}

function lineEndAfter(document: string, position: number): number {
  const lineBreak = document.indexOf("\n", position);
  return lineBreak === -1 ? document.length : lineBreak;
}

function isBlankLine(document: string, from: number, to: number): boolean {
  return document.slice(from, to).trim().length === 0;
}

/**
 * Finds the non-blank, blank-line-bounded Markdown paragraph containing a
 * CodeMirror document offset. JavaScript and CodeMirror both use UTF-16
 * offsets, so no code-point conversion can split or shift emoji/CJK offsets.
 */
export function findMarkdownParagraphRange(document: string, position: number): MarkdownParagraphRange | null {
  if (document.length === 0) return null;

  const cursor = Math.min(document.length, Math.max(0, position));
  let from = lineStartBefore(document, cursor);
  let to = lineEndAfter(document, cursor);
  if (isBlankLine(document, from, to)) return null;

  while (from > 0) {
    const previousEnd = from - 1;
    const previousStart = lineStartBefore(document, previousEnd);
    if (isBlankLine(document, previousStart, previousEnd)) break;
    from = previousStart;
  }

  while (to < document.length) {
    const nextStart = to + 1;
    const nextEnd = lineEndAfter(document, nextStart);
    if (isBlankLine(document, nextStart, nextEnd)) break;
    to = nextEnd;
  }

  return { from, to };
}

/**
 * Returns only the line starts inside an already-known paragraph. This never
 * walks unrelated paragraphs while the cursor moves through a long document.
 */
export function findMarkdownParagraphLineStarts(document: string, paragraph: MarkdownParagraphRange): number[] {
  const lineStarts = [paragraph.from];
  let lineBreak = document.indexOf("\n", paragraph.from);
  while (lineBreak !== -1 && lineBreak < paragraph.to) {
    lineStarts.push(lineBreak + 1);
    lineBreak = document.indexOf("\n", lineBreak + 1);
  }
  return lineStarts;
}
