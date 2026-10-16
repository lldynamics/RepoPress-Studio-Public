import type { TextRange } from "./markdownWriting";

export interface MarkdownImageInsertion {
  text: string;
  selection: TextRange;
  markdown: string;
}

export interface MarkdownImageInput {
  markdownPath: string;
  fallbackAlt: string;
}

function safeAltText(value: string): string {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/\]/g, "\\]")
    .replace(/[\r\n]+/g, " ")
    .trim();
}

function safeMarkdownPath(value: string): string {
  return value
    .trim()
    .replace(/\\/g, "/")
    .replace(/ /g, "%20")
    .replace(/\(/g, "%28")
    .replace(/\)/g, "%29");
}

function normalizedSelection(source: string, selection: TextRange): TextRange {
  const first = Math.max(0, Math.min(source.length, selection.from));
  const second = Math.max(0, Math.min(source.length, selection.to));
  return {
    from: Math.min(first, second),
    to: Math.max(first, second),
  };
}

function imageMarkdown(input: MarkdownImageInput, alt: string): string {
  return `![${alt}](${safeMarkdownPath(input.markdownPath)})`;
}

export function insertMarkdownImage(
  source: string,
  selection: TextRange,
  markdownPath: string,
  fallbackAlt: string,
): MarkdownImageInsertion {
  const { from, to } = normalizedSelection(source, selection);
  const selectedAlt = safeAltText(source.slice(from, to));
  const alt = selectedAlt || safeAltText(fallbackAlt) || "图片说明";
  const markdown = imageMarkdown({ markdownPath, fallbackAlt }, alt);
  const text = source.slice(0, from) + markdown + source.slice(to);
  const altStart = from + 2;

  return {
    text,
    markdown,
    selection: { from: altStart, to: altStart + alt.length },
  };
}

/**
 * Inserts a group of imported images at once. A non-empty source selection is
 * intentionally reused as the alt text for every image, matching the single
 * image insertion behavior and keeping multi-select imports predictable.
 */
export function insertMarkdownImages(
  source: string,
  selection: TextRange,
  images: MarkdownImageInput[],
): MarkdownImageInsertion {
  const { from, to } = normalizedSelection(source, selection);
  if (images.length === 0) {
    return { text: source, markdown: "", selection: { from, to } };
  }

  const selectedAlt = safeAltText(source.slice(from, to));
  const markdown = images
    .map((image) => {
      const alt = selectedAlt || safeAltText(image.fallbackAlt) || "图片说明";
      return imageMarkdown(image, alt);
    })
    .join("\n");
  const text = source.slice(0, from) + markdown + source.slice(to);
  const firstAlt = selectedAlt || safeAltText(images[0].fallbackAlt) || "图片说明";
  const altStart = from + 2;

  return {
    text,
    markdown,
    selection: { from: altStart, to: altStart + firstAlt.length },
  };
}
