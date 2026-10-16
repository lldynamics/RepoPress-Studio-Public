import { markdownFrontMatterBodyOffset } from "./markdownSyntaxContext";

export interface MarkdownCursorRange { from: number; to: number }
export interface MarkdownCursorPosition {
  line: number; column: number; utf16Column: number; lineStart: number; lineEnd: number;
}
export interface GoToLineResult { range: MarkdownCursorRange | null; error?: string; line?: number }
export interface MarkdownFenceContext {
  marker: "`" | "~"; markerLength: number; opening: MarkdownCursorRange; closing: MarkdownCursorRange | null;
  openingLine: number; closingLine: number | null; isClosed: boolean;
}

interface Line { number: number; start: number; contentEnd: number; end: number }
function clamp(value: number, max: number): number { return Number.isFinite(value) ? Math.max(0, Math.min(max, Math.trunc(value))) : 0; }
function linesOf(source: string): Line[] {
  const result: Line[] = []; let start = 0; let number = 1;
  while (start < source.length) {
    const newline = source.indexOf("\n", start); const end = newline < 0 ? source.length : newline + 1;
    const contentEnd = (newline >= 0 && newline > start && source[newline - 1] === "\r") ? newline - 1 : (newline < 0 ? source.length : newline);
    result.push({ number, start, contentEnd, end }); number += 1; start = end;
  }
  if (!source.length || start === source.length && (source.endsWith("\n") || source.endsWith("\r"))) result.push({ number, start: source.length, contentEnd: source.length, end: source.length });
  return result;
}

export function clampMarkdownSelection(source: string, selection: MarkdownCursorRange): MarkdownCursorRange {
  const from = clamp(selection?.from ?? 0, source.length); const to = clamp(selection?.to ?? from, source.length);
  return { from: Math.min(from, to), to: Math.max(from, to) };
}

export function markdownCursorPosition(source: string, selection: MarkdownCursorRange): MarkdownCursorPosition {
  const safe = clampMarkdownSelection(source, selection); const cursor = safe.to; const lines = linesOf(source);
  const line = lines.find((item, index) => cursor < item.end || index === lines.length - 1) ?? lines[0];
  const offset = Math.max(0, Math.min(cursor, line.contentEnd) - line.start);
  const prefix = source.slice(line.start, line.start + offset);
  return { line: line.number, column: Array.from(prefix).length + 1, utf16Column: offset + 1, lineStart: line.start, lineEnd: line.contentEnd };
}
export function markdownLineCount(source: string): number { return linesOf(source).length; }

export function parseGoToLine(request: string, lineCount: number): { line: number | null; error?: string } {
  const value = request.trim();
  if (!value) return { line: null, error: "请输入行号。" };
  if (!/^\d+$/.test(value)) return { line: null, error: "行号必须是整数。" };
  const line = Number(value); if (!Number.isSafeInteger(line) || line < 1 || line > lineCount) return { line: null, error: `行号必须在 1–${lineCount} 之间。` };
  return { line };
}

export function goToMarkdownLine(source: string, request: string): GoToLineResult {
  const lines = linesOf(source); const parsed = parseGoToLine(request, lines.length);
  if (!parsed.line) return { range: null, error: parsed.error };
  const line = lines[parsed.line - 1]; return { line: parsed.line, range: { from: line.start, to: line.start } };
}

function fenceAtLine(source: string, line: Line): { marker: "`" | "~"; length: number; range: MarkdownCursorRange } | null {
  const text = source.slice(line.start, line.contentEnd); const match = text.match(/^ {0,3}(`{3,}|~{3,})/); if (!match) return null;
  const marker = match[1][0] as "`" | "~"; const length = match[1].length;
  if (marker === "`" && text.slice(match[0].length).includes("`")) return null;
  return { marker, length, range: { from: line.start + match[0].length - length, to: line.start + match[0].length } };
}
function closingAtLine(source: string, line: Line, opening: { marker: "`" | "~"; length: number }): MarkdownCursorRange | null {
  const text = source.slice(line.start, line.contentEnd); const match = text.match(/^ {0,3}(`{3,}|~{3,})[ \t]*$/);
  if (!match || match[1][0] !== opening.marker || match[1].length < opening.length) return null;
  return { from: line.start + match[0].indexOf(match[1]), to: line.start + match[0].indexOf(match[1]) + match[1].length };
}

export function markdownFenceContexts(source: string): MarkdownFenceContext[] {
  const body = markdownFrontMatterBodyOffset(source); if (!Number.isFinite(body)) return [];
  const lines = linesOf(source); const result: MarkdownFenceContext[] = []; let active: { marker: "`" | "~"; length: number; opening: MarkdownCursorRange; openingLine: number } | null = null;
  for (const line of lines) {
    if (line.start < body) continue;
    if (active) { const closing = closingAtLine(source, line, active); if (closing) { result.push({ marker: active.marker, markerLength: active.length, opening: active.opening, openingLine: active.openingLine, closing, closingLine: line.number, isClosed: true }); active = null; } }
    else { const opening = fenceAtLine(source, line); if (opening) active = { marker: opening.marker, length: opening.length, opening: opening.range, openingLine: line.number }; }
  }
  if (active) result.push({ marker: active.marker, markerLength: active.length, opening: active.opening, openingLine: active.openingLine, closing: null, closingLine: null, isClosed: false });
  return result;
}

export function markdownFenceAtSelection(source: string, selection: MarkdownCursorRange): MarkdownFenceContext | null {
  const safe = clampMarkdownSelection(source, selection); return markdownFenceContexts(source).find((fence) => {
    const end = fence.closing?.to ?? source.length; return safe.to >= fence.opening.from && safe.from <= end && safe.to >= fence.opening.from;
  }) ?? null;
}

export function counterpartMarkdownFence(source: string, selection: MarkdownCursorRange): MarkdownCursorRange | null {
  const fence = markdownFenceAtSelection(source, selection); if (!fence) return null; const cursor = clampMarkdownSelection(source, selection).to;
  if (!fence.closing) return fence.opening;
  if (cursor >= fence.opening.from && cursor <= fence.opening.to) return fence.closing;
  if (cursor >= fence.closing.from && cursor <= fence.closing.to) return fence.opening;
  return fence.opening;
}
