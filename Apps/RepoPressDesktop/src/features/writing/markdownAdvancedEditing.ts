import type { TextEditResult, TextRange } from "./markdownWriting";
import { markdownFrontMatterBodyOffset, transitionMarkdownFence, type MarkdownFenceState } from "./markdownSyntaxContext";

export type MarkdownLineEditingCommand =
  | "moveUp" | "moveDown" | "duplicateAbove" | "duplicateBelow"
  | "toggleTaskCompletion" | "deleteLine" | "toggleComment" | "removeFormatting";

interface Line { text: string; start: number; end: number; fullEnd: number; newline: string; }
function linesOf(source: string): Line[] {
  const out: Line[] = []; let start = 0;
  while (start <= source.length) {
    const nl = source.indexOf("\n", start); const fullEnd = nl < 0 ? source.length : nl + 1;
    const raw = source.slice(start, nl < 0 ? source.length : nl);
    out.push({ text: raw.endsWith("\r") ? raw.slice(0, -1) : raw, start, end: nl < 0 ? source.length : fullEnd - (raw.endsWith("\r") ? 2 : 1), fullEnd, newline: nl < 0 ? "" : raw.endsWith("\r") ? "\r\n" : "\n" });
    if (nl < 0) break; start = nl + 1;
  }
  return out;
}
function clampRange(source: string, input: TextRange): TextRange { const a = Math.max(0, Math.min(source.length, input.from)); const b = Math.max(0, Math.min(source.length, input.to)); return { from: Math.min(a, b), to: Math.max(a, b) }; }
function selectedIndices(ls: Line[], r: TextRange): [number, number] {
  let first = ls.findIndex((l) => r.from >= l.start && r.from < l.fullEnd); if (first < 0) first = ls.length - 1;
  let last = ls.findIndex((l) => r.to > l.start && r.to <= l.fullEnd); if (last < 0) last = ls.length - 1;
  if (r.to > r.from && last > first && r.to === ls[last].start) last--;
  return [Math.max(0, first), Math.max(first, last)];
}
function protectedLines(source: string, ls: Line[]): boolean[] {
  const result = ls.map(() => false); const body = markdownFrontMatterBodyOffset(source);
  let state: MarkdownFenceState = { marker: null, length: 0 };
  ls.forEach((line, i) => {
    if (line.start < body) result[i] = true;
    const transition = transitionMarkdownFence(line.text, state); if (state.marker || transition.delimiterLine) result[i] = true;
    state = transition.state;
  });
  return result;
}
function endpointMap(ls: Line[], pos: number): { index: number; column: number } { const found = ls.findIndex((l) => pos >= l.start && pos < l.fullEnd); const i = Math.min(ls.length - 1, found < 0 ? ls.length - 1 : found); return { index: i, column: Math.max(0, Math.min(ls[i].text.length, pos - ls[i].start)) }; }
function render(items: Line[], texts: string[]): string { return items.map((l, i) => texts[i] + l.newline).join(""); }
function reassignNewlines(items: Line[], original: Line[]): Line[] {
  const style = original.find((l) => l.newline)?.newline || "\n";
  const trailing = original[original.length - 1]?.newline || "";
  return items.map((line, i) => ({ ...line, newline: i === items.length - 1 ? trailing : (original[i]?.newline || style) }));
}
function resultFor(_source: string, r: TextRange, original: Line[], ls: Line[], texts: string[], map: (p: { index: number; column: number }) => { index: number; column: number } = (p) => p): TextEditResult { const output = render(ls, texts); const a = endpointMap(original, r.from), b = endpointMap(original, r.to); const aa = map(a), bb = map(b); const offsets = (p: { index: number; column: number }) => { let n = 0; for (let i = 0; i < p.index; i++) n += texts[i].length + ls[i].newline.length; return n + Math.min(p.column, texts[p.index].length); }; return { text: output, selection: { from: offsets(aa), to: offsets(bb) } }; }

export function planMarkdownLineEdit(source: string, input: TextRange, command: MarkdownLineEditingCommand): TextEditResult | null {
  const r = clampRange(source, input), ls = linesOf(source), [first, last] = selectedIndices(ls, r), blocked = protectedLines(source, ls);
  if (Array.from({ length: last - first + 1 }, (_, n) => blocked[first + n]).some(Boolean)) return null;
  const texts = ls.map((l) => l.text), start = first, end = last, selected = (i: number) => i >= start && i <= end;
  if (command === "moveUp" || command === "moveDown") {
    const target = command === "moveUp" ? first - 1 : last + 1; if (target < 0 || target >= ls.length || blocked[target]) return null;
    const order = ls.map((_, i) => i); const block = order.splice(first, last - first + 1); order.splice(command === "moveUp" ? target : target - (last - first), 0, ...block);
    const newLines = reassignNewlines(order.map((i) => ls[i]), ls), newTexts = order.map((i) => texts[i]), map = (p: { index: number; column: number }) => ({ index: order.indexOf(p.index), column: p.column });
    return resultFor(source, r, ls, newLines, newTexts, map);
  }
  if (command === "duplicateAbove" || command === "duplicateBelow") {
    const copy = ls.slice(first, last + 1).map((l) => ({ ...l })), copyTexts = texts.slice(first, last + 1), insertAt = command === "duplicateAbove" ? first : last + 1;
    const rawLines = [...ls.slice(0, insertAt), ...copy, ...ls.slice(insertAt)], newLines = reassignNewlines(rawLines, ls), newTexts = [...texts.slice(0, insertAt), ...copyTexts, ...texts.slice(insertAt)];
    const map = (p: { index: number; column: number }) => selected(p.index)
      ? { index: command === "duplicateAbove" ? p.index : insertAt + (p.index - first), column: p.column }
      : { index: p.index + (p.index >= insertAt ? copy.length : 0), column: p.column };
    return resultFor(source, r, ls, newLines, newTexts, map);
  }
  if (command === "deleteLine") { const newLines = ls.filter((_, i) => !selected(i)), newTexts = texts.filter((_, i) => !selected(i)); if (!newLines.length) return { text: "", selection: { from: 0, to: 0 } }; if (last === ls.length - 1 && first > 0 && ls[last].newline === "") { const previous = first - 1; newLines[previous] = { ...newLines[previous], newline: "" }; } const at = Math.min(first, newLines.length - 1); return resultFor(source, r, ls, newLines, newTexts, () => ({ index: at, column: 0 })); }
  if (command === "toggleTaskCompletion") {
    const task = /^\s*([-+*])\s+\[([ xX])\](\s|$)/; const anyOpen = texts.some((t, i) => selected(i) && task.test(t) && task.exec(t)?.[2].toLowerCase() === " ");
    texts.forEach((t, i) => { if (!selected(i)) return; texts[i] = t.replace(task, (_m, bullet, _state, rest) => `${t.match(/^\s*/)?.[0] ?? ""}${bullet} [${anyOpen ? "x" : " "}]${rest}`); });
  } else if (command === "toggleComment") {
    texts.forEach((t, i) => { if (!selected(i)) return; const m = t.match(/^(\s*)(?:<!--\s?(.*?)\s?-->)$/); texts[i] = m ? `${m[1]}${m[2]}` : t.replace(/^(\s*)/, "$1<!-- ") + " -->"; });
  } else if (command === "removeFormatting") {
    texts.forEach((t, i) => { if (!selected(i)) return; texts[i] = t.replace(/^(\s*)(#{1,6}\s+|>\s+|[-+*]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)/, "$1").replace(/(\*\*|__|~~|`)([^\n]*?)\1/g, "$2").replace(/(?<![\w*])\*([^*\n]+)\*(?![\w*])/g, "$1").replace(/(?<![\w_])_([^_\n]+)_(?![\w_])/g, "$1"); });
  }
  return resultFor(source, r, ls, ls, texts);
}
