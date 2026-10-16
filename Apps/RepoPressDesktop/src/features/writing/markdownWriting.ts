export interface TextRange { from: number; to: number }
export interface TextEditResult { text: string; selection: TextRange }
export type MarkdownFormat =
  | "bold" | "italic" | "strike" | "code" | "link"
  | "heading" | "quote" | "unorderedList" | "orderedList"
  | "taskList" | "codeBlock" | "horizontalRule";

function range(text: string, input: TextRange): TextRange {
  const from = Math.max(0, Math.min(text.length, Math.min(input.from, input.to)));
  const to = Math.max(from, Math.min(text.length, Math.max(input.from, input.to)));
  return { from, to };
}

function replace(text: string, selection: TextRange, from: number, to: number, value: string): TextEditResult {
  const delta = value.length - (to - from);
  const map = (at: number) => at <= from ? at : at >= to ? at + delta : from + value.length;
  return { text: text.slice(0, from) + value + text.slice(to), selection: { from: map(selection.from), to: map(selection.to) } };
}

function toggleInline(text: string, selected: TextRange, marker: string, fallback: string): TextEditResult {
  const value = text.slice(selected.from, selected.to);
  const wrapped = value.length >= marker.length * 2 && value.startsWith(marker) && value.endsWith(marker);
  if (wrapped) return replace(text, selected, selected.from, selected.to, value.slice(marker.length, -marker.length));
  if (!value) {
    return {
      text: text.slice(0, selected.from) + marker + fallback + marker + text.slice(selected.to),
      selection: { from: selected.from + marker.length, to: selected.from + marker.length + fallback.length },
    };
  }
  return replace(text, selected, selected.from, selected.to, marker + value + marker);
}

function selectedLines(text: string, selected: TextRange): { start: number; end: number; lines: string[] } {
  const start = text.lastIndexOf("\n", Math.max(0, selected.from - 1)) + 1;
  const nextBreak = text.indexOf("\n", selected.to);
  const end = nextBreak < 0 ? text.length : nextBreak;
  return { start, end, lines: text.slice(start, end).split("\n") };
}

function toggleLinePrefix(text: string, selected: TextRange, prefix: string, transform?: (line: string, index: number) => string): TextEditResult {
  const block = selectedLines(text, selected);
  const lines = block.lines;
  const active = lines.every((line) => line.startsWith(prefix));
  const output = lines.map((line, index) => transform ? transform(line, index) : (active ? line.slice(prefix.length) : prefix + line)).join("\n");
  return replace(text, selected, block.start, block.end, output);
}

export function applyMarkdownFormat(source: string, input: TextRange, format: MarkdownFormat): TextEditResult {
  const selection = range(source, input);
  switch (format) {
    case "bold": return toggleInline(source, selection, "**", "粗体");
    case "italic": return toggleInline(source, selection, "*", "斜体");
    case "strike": return toggleInline(source, selection, "~~", "删除线");
    case "code": return toggleInline(source, selection, "`", "代码");
    case "link": {
      const value = source.slice(selection.from, selection.to);
      const existing = value.match(/^\[([^\]]*)\]\(([^)]*)\)$/);
      if (existing) return replace(source, selection, selection.from, selection.to, existing[1]);
      const label = value || "链接文字";
      const inserted = `[${label}](https://)`;
      return {
        text: source.slice(0, selection.from) + inserted + source.slice(selection.to),
        selection: value
          ? { from: selection.from + inserted.length - 8, to: selection.from + inserted.length - 1 }
          : { from: selection.from + 1, to: selection.from + 1 + label.length },
      };
    }
    case "heading": return toggleLinePrefix(source, selection, "# ", (line) => {
      const match = line.match(/^(#{1,6})\s+/); return match ? line.slice(match[0].length) : "# " + line;
    });
    case "quote": return toggleLinePrefix(source, selection, "> ");
    case "unorderedList": return toggleLinePrefix(source, selection, "- ");
    case "orderedList": return toggleLinePrefix(source, selection, "1. ", (line, index) => {
      if (/^\d+\.\s+/.test(line)) return line.replace(/^\d+\.\s+/, "");
      return `${index + 1}. ${line}`;
    });
    case "taskList": return toggleLinePrefix(source, selection, "- [ ] ", (line) => {
      if (/^- \[[ xX]\]\s+/.test(line)) return line.replace(/^- \[[ xX]\]\s+/, "");
      return "- [ ] " + line.replace(/^[-*+]\s+/, "");
    });
    case "codeBlock": {
      const block = selectedLines(source, selection); const value = source.slice(block.start, block.end);
      const fenced = value.startsWith("```") && value.endsWith("```");
      const output = fenced ? value.slice(3, -3).replace(/^\n|\n$/g, "") : "```\n" + value + "\n```";
      return replace(source, selection, block.start, block.end, output);
    }
    case "horizontalRule": return replace(source, selection, selection.from, selection.to, "\n---\n");
  }
}

export interface MarkdownOutlineItem { level: number; title: string; line: number; from: number; to: number }
export function getMarkdownOutline(text: string): MarkdownOutlineItem[] {
  const result: MarkdownOutlineItem[] = [];
  let fenced = false;
  let offset = 0;
  text.split("\n").forEach((line, index) => {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    else if (!fenced) {
      const match = line.match(/^\s*(#{1,6})\s+(.+?)\s*#*\s*$/);
      if (match) {
        const title = match[2].trim();
        const titleOffset = line.indexOf(match[2]);
        result.push({ level: match[1].length, title, line: index + 1, from: offset + titleOffset, to: offset + titleOffset + title.length });
      }
    }
    offset += line.length + 1;
  });
  return result;
}

export interface WritingStats { words: number; characters: number; lines: number; readingMinutes: number }
export function getWritingStats(text: string): WritingStats {
  // Keep Han characters distinct: one Chinese character is one writing unit,
  // while every other letter/number run is a word. Marks keep composed and
  // decomposed forms of a word together.
  const hanCharacters = text.match(/\p{Ideographic}/gu)?.length ?? 0;
  const otherWords = text
    .replace(/\p{Ideographic}/gu, " ")
    .match(/[\p{L}\p{N}][\p{L}\p{N}\p{M}]*/gu)?.length ?? 0;
  const words = hanCharacters + otherWords;
  const readingMinutes = words ? Math.max(1, Math.ceil(hanCharacters / 500 + otherWords / 250)) : 0;
  return { words, characters: Array.from(text).length, lines: text ? text.split("\n").length : 0, readingMinutes };
}

export interface FindOptions { caseSensitive?: boolean; wholeWord?: boolean; regularExpression?: boolean }
export interface Match { from: number; to: number }
export interface FindResult { matches: Match[]; error: string | null }
export interface ReplaceResult extends TextEditResult {
  replacementCount: number;
  /** The match used for a single replacement, if there was one. */
  match: Match | null;
  /** Zero-based position in the original result set, or -1 when none matched. */
  index: number;
  total: number;
  wrapped: boolean;
}

interface DetailedMatch extends Match { value: string; captures: Array<string | undefined> }
interface DetailedFindResult { matches: DetailedMatch[]; error: string | null }

function escapeRegularExpression(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function codePointBefore(text: string, index: number): string {
  if (index <= 0) return "";
  const finalUnit = text.charCodeAt(index - 1);
  const start = finalUnit >= 0xdc00 && finalUnit <= 0xdfff && index >= 2 ? index - 2 : index - 1;
  return String.fromCodePoint(text.codePointAt(start) ?? 0);
}

function codePointAt(text: string, index: number): string {
  return index >= text.length ? "" : String.fromCodePoint(text.codePointAt(index) ?? 0);
}

function isUnicodeWordCharacter(value: string): boolean {
  return /^[\p{L}\p{N}\p{M}_]$/u.test(value);
}

function isWholeWord(text: string, match: Match): boolean {
  return !isUnicodeWordCharacter(codePointBefore(text, match.from)) && !isUnicodeWordCharacter(codePointAt(text, match.to));
}

function advanceUnicodeIndex(text: string, index: number): number {
  if (index >= text.length) return index + 1;
  const value = text.codePointAt(index) ?? 0;
  return index + (value > 0xffff ? 2 : 1);
}

function inspectDetailedMatches(text: string, query: string, options: FindOptions = {}): DetailedFindResult {
  if (!query) return { matches: [], error: null };
  try {
    const source = options.regularExpression ? query : escapeRegularExpression(query);
    const expression = new RegExp(source, options.caseSensitive ? "gu" : "giu");
    const matches: DetailedMatch[] = [];
    let match: RegExpExecArray | null;
    while ((match = expression.exec(text))) {
      const value = match[0] ?? "";
      const from = match.index;
      const item = { from, to: from + value.length, value, captures: match.slice(1) };
      if (!options.wholeWord || isWholeWord(text, item)) matches.push(item);
      // RegExp#exec does not always advance after a zero-width match. Advance
      // by a Unicode scalar so an emoji cannot be split into two positions.
      if (!value) expression.lastIndex = advanceUnicodeIndex(text, expression.lastIndex);
    }
    return { matches, error: null };
  } catch {
    return { matches: [], error: "正则表达式无效" };
  }
}

export function inspectMatches(text: string, query: string, options: FindOptions = {}): FindResult {
  const result = inspectDetailedMatches(text, query, options);
  return { matches: result.matches.map(({ from, to }) => ({ from, to })), error: result.error };
}

export function findMatches(text: string, query: string, options: FindOptions = {}): Match[] {
  return inspectMatches(text, query, options).matches;
}
export function findNextMatch(text: string, query: string, start: number, direction: "next" | "previous" = "next", options: FindOptions = {}): Match | null {
  const matches = findMatches(text, query, options); if (!matches.length) return null; const cursor = Math.max(0, Math.min(text.length, start));
  if (direction === "next") return matches.find((m) => m.from >= cursor) || matches[0];
  return [...matches].reverse().find((m) => m.to <= cursor) || matches[matches.length - 1];
}
export function replaceCurrent(text: string, match: Match | null, replacement: string): TextEditResult { if (!match) return { text, selection: { from: 0, to: 0 } }; return replace(text, match, match.from, match.to, replacement); }

function expandRegularExpressionReplacement(template: string, match: DetailedMatch): string {
  return template.replace(/\$(?:\$|&|0|[1-9]\d?)/g, (token) => {
    if (token === "$$") return "$";
    if (token === "$&" || token === "$0") return match.value;
    const first = Number(token[1]);
    const second = token.length === 3 ? Number(token[2]) : null;
    const twoDigit = second === null ? first : first * 10 + second;
    if (second !== null && twoDigit <= match.captures.length) return match.captures[twoDigit - 1] ?? "";
    if (first <= match.captures.length) return (match.captures[first - 1] ?? "") + (second === null ? "" : token[2]);
    return token;
  });
}

function replacementFor(match: DetailedMatch, replacement: string, options: FindOptions): string {
  return options.regularExpression ? expandRegularExpressionReplacement(replacement, match) : replacement;
}

function unchangedReplaceResult(text: string, total = 0): ReplaceResult {
  return { text, selection: { from: 0, to: 0 }, replacementCount: 0, match: null, index: -1, total, wrapped: false };
}

/** Replaces an exact current selection, otherwise the next match and then wraps. */
export function replaceCurrentOrNext(text: string, query: string, replacement: string, selection: TextRange, options: FindOptions = {}): ReplaceResult {
  const inspected = inspectDetailedMatches(text, query, options);
  if (inspected.error || !inspected.matches.length) return unchangedReplaceResult(text);
  const matches = inspected.matches;
  const exactIndex = matches.findIndex((match) => match.from === selection.from && match.to === selection.to);
  const cursor = Math.max(0, Math.min(text.length, selection.to));
  const nextIndex = matches.findIndex((match) => match.from >= cursor);
  const index = exactIndex >= 0 ? exactIndex : nextIndex >= 0 ? nextIndex : 0;
  const match = matches[index];
  const value = replacementFor(match, replacement, options);
  const result = replace(text, match, match.from, match.to, value);
  return {
    text: result.text,
    selection: result.selection,
    replacementCount: 1,
    match: { from: match.from, to: match.to },
    index,
    total: matches.length,
    wrapped: exactIndex < 0 && nextIndex < 0,
  };
}

export function replaceAll(text: string, query: string, replacement: string, options: FindOptions = {}): ReplaceResult {
  const inspected = inspectDetailedMatches(text, query, options);
  if (inspected.error || !inspected.matches.length) return unchangedReplaceResult(text);
  let output = text;
  for (let index = inspected.matches.length - 1; index >= 0; index--) {
    const match = inspected.matches[index];
    output = output.slice(0, match.from) + replacementFor(match, replacement, options) + output.slice(match.to);
  }
  return { text: output, selection: { from: 0, to: 0 }, replacementCount: inspected.matches.length, match: null, index: -1, total: inspected.matches.length, wrapped: false };
}

/** Plans the list continuation used by Enter without taking over CodeMirror's undo stack. */
export function planMarkdownListContinuation(text: string, cursor: number): TextEditResult | null {
  const safeCursor = Math.max(0, Math.min(text.length, cursor));
  const lineStart = text.lastIndexOf("\n", Math.max(0, safeCursor - 1)) + 1;
  if (isInsideFencedCodeBlock(text, lineStart)) return null;

  const nextLineBreak = text.indexOf("\n", lineStart);
  const rawLineEnd = nextLineBreak < 0 ? text.length : nextLineBreak;
  const lineEnd = rawLineEnd > lineStart && text[rawLineEnd - 1] === "\r" ? rawLineEnd - 1 : rawLineEnd;
  const fullLineMarker = markdownLineMarker(text.slice(lineStart, lineEnd));
  if (fullLineMarker && !fullLineMarker.content.trim()) {
    return {
      text: text.slice(0, lineStart) + text.slice(lineEnd),
      selection: { from: lineStart, to: lineStart },
    };
  }

  const beforeCursor = text.slice(lineStart, safeCursor);
  const marker = markdownLineMarker(beforeCursor);
  if (!marker || !marker.content.trim()) return null;

  const inserted = `\n${marker.continuation}`;
  return {
    text: text.slice(0, safeCursor) + inserted + text.slice(safeCursor),
    selection: { from: safeCursor + inserted.length, to: safeCursor + inserted.length },
  };
}

interface MarkdownLineMarker { continuation: string; content: string }

function markdownLineMarker(line: string): MarkdownLineMarker | null {
  let match = line.match(/^(\s*)([-+*])\s+\[([ xX])\]\s*(.*)$/);
  if (match) return { continuation: `${match[1]}${match[2]} [ ] `, content: match[4] };

  match = line.match(/^(\s*)(\d+)([.)])\s+(.*)$/);
  if (match) {
    const current = Number(match[2]);
    if (!Number.isSafeInteger(current) || current >= Number.MAX_SAFE_INTEGER) return null;
    return { continuation: `${match[1]}${current + 1}${match[3]} `, content: match[4] };
  }

  match = line.match(/^(\s*)(\d+)(、)(\s*)(.*)$/);
  if (match) {
    const current = Number(match[2]);
    if (!Number.isSafeInteger(current) || current >= Number.MAX_SAFE_INTEGER) return null;
    return { continuation: `${match[1]}${current + 1}${match[3]}${match[4]}`, content: match[5] };
  }

  match = line.match(/^(\s*)([-+*])\s+(.*)$/);
  if (match) return { continuation: `${match[1]}${match[2]} `, content: match[3] };

  match = line.match(/^(\s*)(>+)\s+(.*)$/);
  if (match) return { continuation: `${match[1]}${match[2]} `, content: match[3] };

  return null;
}

function isInsideFencedCodeBlock(text: string, lineStart: number): boolean {
  let active: { marker: "`" | "~"; length: number } | null = null;
  for (const line of text.slice(0, lineStart).split(/\r?\n/)) {
    const match = line.match(/^\s*(`{3,}|~{3,})/);
    if (!match) continue;
    const marker = match[1][0] as "`" | "~";
    if (!active) active = { marker, length: match[1].length };
    else if (active.marker === marker && match[1].length >= active.length) active = null;
  }
  return active !== null;
}

export const formatMarkdown = applyMarkdownFormat;
