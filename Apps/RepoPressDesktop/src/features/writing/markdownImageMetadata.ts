import type { TextRange } from "./markdownWriting";
import { addDefaultFrontMatter, adjustSelectionAfterFrontMatterChange, parseFrontMatter, updateFrontMatterField } from "../frontmatter/frontMatter";
import { isMarkdownEscaped, markdownFrontMatterBodyOffset, transitionMarkdownFence, type MarkdownFenceState } from "./markdownSyntaxContext";

export interface MarkdownImageReference {
  path: string;
  from: number;
  to: number;
  alt: string;
  title: string | null;
}

function maskRange(characters: string[], from: number, to: number): void {
  for (let index = from; index < to; index += 1) {
    if (characters[index] !== "\n" && characters[index] !== "\r") characters[index] = " ";
  }
}

function maskInlineCode(characters: string[], source: string, from: number, to: number): void {
  let cursor = from;
  while (cursor < to) {
    if (source[cursor] !== "`") { cursor += 1; continue; }
    let openingEnd = cursor + 1;
    while (openingEnd < to && source[openingEnd] === "`") openingEnd += 1;
    const delimiter = source.slice(cursor, openingEnd);
    let closing = source.indexOf(delimiter, openingEnd);
    while (closing >= 0 && closing < to && (source[closing - 1] === "`" || source[closing + delimiter.length] === "`")) {
      closing = source.indexOf(delimiter, closing + delimiter.length);
    }
    if (closing < 0 || closing >= to) { cursor = openingEnd; continue; }
    maskRange(characters, cursor, closing + delimiter.length);
    cursor = closing + delimiter.length;
  }
}

/** Masks syntax regions where image-looking text is literal while preserving UTF-16 offsets. */
function visibleMarkdown(source: string): string {
  const characters = source.split("");
  let offset = 0;
  const bodyOffset = markdownFrontMatterBodyOffset(source);
  let fence: MarkdownFenceState = { marker: null, length: 0 };

  while (offset < source.length) {
    const newline = source.indexOf("\n", offset);
    const lineEnd = newline < 0 ? source.length : newline;
    const nextOffset = newline < 0 ? source.length : newline + 1;
    const line = source.slice(offset, lineEnd).replace(/\r$/, "");
    if (offset < bodyOffset) {
      maskRange(characters, offset, nextOffset);
      offset = nextOffset;
      continue;
    }

    const wasFenced = Boolean(fence.marker);
    const transition = transitionMarkdownFence(line, fence);
    fence = transition.state;
    if (wasFenced || transition.delimiterLine) {
      maskRange(characters, offset, nextOffset);
      offset = nextOffset;
      continue;
    }
    maskInlineCode(characters, source, offset, lineEnd);
    offset = nextOffset;
  }
  return characters.join("");
}

function unescapeMarkdown(value: string): string {
  return value.replace(/\\([\\\[\]"'])/g, "$1");
}

function destinationAndTitle(inner: string): { path: string; title: string | null } | null {
  const trimmed = inner.trim();
  if (!trimmed) return null;
  let pathPart = trimmed;
  let title: string | null = null;

  for (let index = trimmed.length - 1; index >= 0; index -= 1) {
    const quote = trimmed[index];
    if ((quote !== '"' && quote !== "'") || isMarkdownEscaped(trimmed, index)) continue;
    let opening = index - 1;
    while (opening >= 0) {
      if (trimmed[opening] === quote && !isMarkdownEscaped(trimmed, opening) && opening > 0 && /\s/.test(trimmed[opening - 1])) break;
      opening -= 1;
    }
    if (opening >= 0 && !trimmed.slice(index + 1).trim()) {
      title = unescapeMarkdown(trimmed.slice(opening + 1, index));
      pathPart = trimmed.slice(0, opening).trim();
    }
    break;
  }

  if (pathPart.startsWith("<") && pathPart.endsWith(">")) pathPart = pathPart.slice(1, -1);
  return pathPart ? { path: pathPart, title } : null;
}

export function getMarkdownImageReferences(source: string): MarkdownImageReference[] {
  const visible = visibleMarkdown(source);
  const references: MarkdownImageReference[] = [];
  for (let start = 0; start < visible.length - 3; start += 1) {
    if (visible[start] !== "!" || visible[start + 1] !== "[" || isMarkdownEscaped(visible, start)) continue;
    let altEnd = start + 2;
    while (altEnd < visible.length && (visible[altEnd] !== "]" || isMarkdownEscaped(visible, altEnd))) altEnd += 1;
    if (altEnd >= visible.length || visible[altEnd + 1] !== "(") continue;

    let cursor = altEnd + 2;
    let depth = 1;
    let titleQuote: "'" | '"' | null = null;
    while (cursor < visible.length && depth > 0) {
      const character = visible[cursor];
      if (isMarkdownEscaped(visible, cursor)) { cursor += 1; continue; }
      if (titleQuote) {
        if (character === titleQuote) titleQuote = null;
      } else if ((character === '"' || character === "'") && /\s/.test(visible[cursor - 1] ?? "")) {
        titleQuote = character;
      } else if (character === "(") depth += 1;
      else if (character === ")") depth -= 1;
      if (depth > 0) cursor += 1;
    }
    if (depth !== 0) continue;

    const parsed = destinationAndTitle(source.slice(altEnd + 2, cursor));
    if (!parsed) continue;
    references.push({
      path: parsed.path,
      from: start,
      to: cursor + 1,
      alt: unescapeMarkdown(source.slice(start + 2, altEnd)),
      title: parsed.title,
    });
    start = cursor;
  }
  return references;
}

const normalizedMetadata = (value: string) => value.trim().replace(/\s+/g, " ");
const escapedAlt = (value: string) => normalizedMetadata(value).replace(/\\/g, "\\\\").replace(/\[/g, "\\[").replace(/\]/g, "\\]");
const escapedTitle = (value: string) => normalizedMetadata(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
const renderedDestination = (path: string) => /\s/.test(path) ? `<${path}>` : path;

export function updateMarkdownImageMetadata(source: string, markdownPath: string, alt: string, caption: string): { text: string; selection: TextRange; updatedCount: number } {
  const references = getMarkdownImageReferences(source).filter((reference) => reference.path === markdownPath);
  const nextAlt = escapedAlt(alt);
  const nextCaption = escapedTitle(caption);
  let text = source;
  for (const reference of [...references].reverse()) {
    const replacement = `![${nextAlt}](${renderedDestination(reference.path)}${nextCaption ? ` "${nextCaption}"` : ""})`;
    text = text.slice(0, reference.from) + replacement + text.slice(reference.to);
  }
  const first = getMarkdownImageReferences(text).find((reference) => reference.path === markdownPath);
  const selection = first
    ? { from: first.from + 2, to: first.from + 2 + nextAlt.length }
    : { from: 0, to: 0 };
  return { text, selection, updatedCount: references.length };
}

export function setMarkdownCoverImage(source: string, path: string, selection: TextRange = { from: 0, to: 0 }): { text: string; selection: TextRange } {
  const withFrontMatter = parseFrontMatter(source) ? source : addDefaultFrontMatter(source);
  const text = updateFrontMatterField(withFrontMatter, "cover", path.trim());
  return { text, selection: adjustSelectionAfterFrontMatterChange(source, text, selection) };
}

export function getMarkdownCoverImage(source: string): string | null {
  return parseFrontMatter(source)?.values.cover.trim() || null;
}
