import type { TextEditResult, TextRange } from "./markdownWriting";
import { markdownFrontMatterBodyOffset, transitionMarkdownFence, type MarkdownFenceState } from "./markdownSyntaxContext";

export type MarkdownTableEditingCommand =
  | "navigateForward" | "navigateBackward" | "format"
  | "insertRowAbove" | "insertRowBelow" | "deleteRow"
  | "insertColumnBefore" | "insertColumnAfter" | "deleteColumn";

export interface MarkdownTableEditingContext {
  rowIndex: number;
  columnIndex: number;
  isSeparatorRow: boolean;
  canDeleteRow: boolean;
  canDeleteColumn: boolean;
}

type Alignment = "none" | "left" | "center" | "right";
interface Line { text: string; start: number; end: number; fullEnd: number; newline: string; }
interface Cell { content: string; from: number; to: number; }
interface Row { cells: string[]; sourceCells: Cell[]; }
interface Table {
  from: number; to: number; rows: Row[]; alignments: Alignment[];
  separatorRow: number; selectedRow: number; selectedColumn: number; caretOffset: number; newline: string;
}
interface Rendered { text: string; ranges: Array<Array<TextRange>>; }

function clampRange(source: string, input: TextRange): TextRange {
  const a = Math.max(0, Math.min(source.length, input.from));
  const b = Math.max(0, Math.min(source.length, input.to));
  return { from: Math.min(a, b), to: Math.max(a, b) };
}

function linesOf(source: string): Line[] {
  if (!source.length) return [];
  const lines: Line[] = [];
  let start = 0;
  while (start < source.length) {
    const breakAt = source.indexOf("\n", start);
    const fullEnd = breakAt < 0 ? source.length : breakAt + 1;
    const raw = source.slice(start, breakAt < 0 ? source.length : breakAt);
    const hasCR = raw.endsWith("\r");
    lines.push({ text: hasCR ? raw.slice(0, -1) : raw, start, end: breakAt < 0 ? source.length : fullEnd - (hasCR ? 2 : 1), fullEnd, newline: breakAt < 0 ? "" : hasCR ? "\r\n" : "\n" });
    start = fullEnd;
  }
  if (source.endsWith("\n")) lines.push({ text: "", start: source.length, end: source.length, fullEnd: source.length, newline: "" });
  return lines;
}

function selectedLine(lines: Line[], sourceLength: number, at: number): number | null {
  if (at === sourceLength) return lines.length - 1;
  const index = lines.findIndex((line) => at >= line.start && at < line.fullEnd);
  return index < 0 ? null : index;
}

function protectedLines(source: string, lines: Line[]): boolean[] {
  const protectedLine = lines.map(() => false);
  const bodyOffset = markdownFrontMatterBodyOffset(source);
  let state: MarkdownFenceState = { marker: null, length: 0 };
  lines.forEach((line, index) => {
    if (line.start < bodyOffset) protectedLine[index] = true;
    const transition = transitionMarkdownFence(line.text, state);
    if (state.marker || transition.delimiterLine) protectedLine[index] = true;
    state = transition.state;
  });
  return protectedLine;
}

function isEscaped(value: string, index: number): boolean {
  let slashes = 0;
  for (let cursor = index - 1; cursor >= 0 && value[cursor] === "\\"; cursor--) slashes++;
  return slashes % 2 === 1;
}

function structuralPipes(value: string): number[] {
  const result: number[] = [];
  let activeTicks = 0;
  for (let index = 0; index < value.length;) {
    if (value[index] === "`" && !isEscaped(value, index)) {
      let end = index + 1;
      while (value[end] === "`") end++;
      const count = end - index;
      if (!activeTicks) activeTicks = count;
      else if (activeTicks === count) activeTicks = 0;
      index = end;
    } else {
      if (value[index] === "|" && !activeTicks && !isEscaped(value, index)) result.push(index);
      index++;
    }
  }
  return result;
}

function trimHorizontal(value: string, from: number, to: number): TextRange {
  while (from < to && (value[from] === " " || value[from] === "\t")) from++;
  while (to > from && (value[to - 1] === " " || value[to - 1] === "\t")) to--;
  return { from, to };
}

function parseRow(line: Line): Row | null {
  const pipes = structuralPipes(line.text);
  if (!pipes.length) return null;
  const first = line.text.search(/[^ \t]/);
  const last = line.text.search(/[^ \t](?=[ \t]*$)/);
  const leading = first >= 0 && line.text[first] === "|";
  const trailing = last >= 0 && line.text[last] === "|";
  const separators = [...pipes];
  let start = 0;
  if (leading) start = separators.shift()! + 1;
  let finish = line.text.length;
  if (trailing) finish = separators.pop()!;
  const ends = [...separators, finish];
  const sourceCells: Cell[] = [];
  for (const end of ends) {
    if (end < start) continue;
    const trimmed = trimHorizontal(line.text, start, end);
    sourceCells.push({ content: line.text.slice(trimmed.from, trimmed.to), from: line.start + trimmed.from, to: line.start + trimmed.to });
    start = end + 1;
  }
  return sourceCells.length ? { cells: sourceCells.map((cell) => cell.content), sourceCells } : null;
}

function separatorAlignments(row: Row): Alignment[] | null {
  const result: Alignment[] = [];
  for (const cell of row.cells) {
    let token = cell.trim();
    const left = token.startsWith(":"), right = token.endsWith(":");
    if (left) token = token.slice(1);
    if (right && token.length) token = token.slice(0, -1);
    if (token.length < 3 || !/^-+$/.test(token)) return null;
    result.push(left && right ? "center" : left ? "left" : right ? "right" : "none");
  }
  return result;
}

function columnAt(row: Row, location: number): number {
  const contained = row.sourceCells.findIndex((cell) => location >= cell.from && location <= cell.to);
  if (contained >= 0) return contained;
  const before = row.sourceCells.map((cell, index) => ({ cell, index })).filter(({ cell }) => location > cell.to).pop();
  return before ? Math.min(before.index + 1, row.cells.length - 1) : 0;
}

function tableAt(source: string, input: TextRange): Table | null {
  const selection = clampRange(source, input), lines = linesOf(source);
  if (!lines.length) return null;
  const currentLine = selectedLine(lines, source.length, selection.from);
  if (currentLine === null) return null;
  const blocked = protectedLines(source, lines);
  for (let separatorLine = 1; separatorLine < lines.length; separatorLine++) {
    const headerLine = separatorLine - 1;
    if (blocked[headerLine] || blocked[separatorLine]) continue;
    const header = parseRow(lines[headerLine]), separator = parseRow(lines[separatorLine]);
    const alignments = separator && separatorAlignments(separator);
    if (!header || !separator || !alignments || !header.cells.length || header.cells.length !== separator.cells.length) continue;
    const rows = [header, separator];
    let lastLine = separatorLine;
    for (let index = separatorLine + 1; index < lines.length && lines[index].text.trim(); index++) {
      if (blocked[index]) break;
      const row = parseRow(lines[index]);
      if (!row) break;
      rows.push(row); lastLine = index;
    }
    if (currentLine < headerLine || currentLine > lastLine) continue;
    const rowIndex = currentLine - headerLine, row = rows[rowIndex];
    const column = columnAt(row, selection.from), cell = row.sourceCells[column];
    return {
      from: lines[headerLine].start, to: lines[lastLine].end, rows, alignments, separatorRow: 1,
      selectedRow: rowIndex, selectedColumn: column,
      caretOffset: Math.max(0, Math.min(cell.to - cell.from, selection.from - cell.from)),
      newline: lines[headerLine].newline || "\n",
    };
  }
  return null;
}

function columnCount(table: Table): number {
  return Math.max(table.alignments.length, ...table.rows.filter((_, index) => index !== table.separatorRow).map((row) => row.cells.length), 0);
}

function padded(values: string[], count: number): string[] { return [...values.slice(0, count), ...Array(Math.max(0, count - values.length)).fill("")]; }
function paddedAlignments(values: Alignment[], count: number): Alignment[] { return [...values.slice(0, count), ...Array(Math.max(0, count - values.length)).fill("none") as Alignment[]]; }
function displayWidth(value: string): number {
  let width = 0;
  for (const character of value) {
    if (/^\p{M}$/u.test(character)) continue;
    width += Array.from(character).every((scalar) => scalar.codePointAt(0)! < 0x80) ? 1 : 2;
  }
  return width;
}
function separatorToken(alignment: Alignment, width: number): string {
  const normalized = Math.max(3, width);
  if (alignment === "left") return ":" + "-".repeat(normalized - 1);
  if (alignment === "center") return ":" + "-".repeat(normalized - 2) + ":";
  if (alignment === "right") return "-".repeat(normalized - 1) + ":";
  return "-".repeat(normalized);
}

function render(table: Table): Rendered {
  const count = columnCount(table), alignments = paddedAlignments(table.alignments, count);
  const normalized = table.rows.map((row, index) => index === table.separatorRow ? Array(count).fill("") as string[] : padded(row.cells, count));
  const widths = Array.from({ length: count }, (_, column) => Math.max(3, ...normalized.filter((_, row) => row !== table.separatorRow).map((cells) => displayWidth(cells[column]))));
  let text = "";
  const ranges: Array<Array<TextRange>> = [];
  normalized.forEach((cells, row) => {
    if (row) text += table.newline;
    text += "| "; const rowRanges: TextRange[] = [];
    cells.forEach((content, column) => {
      const token = row === table.separatorRow
        ? separatorToken(alignments[column], widths[column])
        : content + " ".repeat(Math.max(0, widths[column] - displayWidth(content)));
      const from = text.length; text += token;
      rowRanges.push({ from, to: from + (row === table.separatorRow ? token.length : content.length) });
      text += " |"; if (column + 1 < count) text += " ";
    });
    ranges.push(rowRanges);
  });
  return { text, ranges };
}

function renderedResult(source: string, table: Table, row: number, column: number, caret?: number): TextEditResult | null {
  const rendered = render(table), cell = rendered.ranges[row]?.[column];
  if (!cell) return null;
  const position = caret === undefined ? cell : { from: cell.from + Math.min(Math.max(0, caret), cell.to - cell.from), to: cell.from + Math.min(Math.max(0, caret), cell.to - cell.from) };
  return { text: source.slice(0, table.from) + rendered.text + source.slice(table.to), selection: { from: table.from + position.from, to: table.from + position.to } };
}

function selectionResult(source: string, table: Table, row: number, column: number): TextEditResult | null {
  const cell = table.rows[row]?.sourceCells[column];
  return cell ? { text: source, selection: { from: cell.from, to: cell.to } } : renderedResult(source, table, row, column);
}

function blankRow(count: number): Row { return { cells: Array(count).fill(""), sourceCells: [] }; }

/** Returns table metadata only when the selection is on an editable Markdown table. */
export function getMarkdownTableEditingContext(source: string, selection: TextRange): MarkdownTableEditingContext | null {
  const table = tableAt(source, selection);
  return table ? { rowIndex: table.selectedRow, columnIndex: table.selectedColumn, isSeparatorRow: table.selectedRow === table.separatorRow, canDeleteRow: table.selectedRow > table.separatorRow, canDeleteColumn: columnCount(table) > 1 } : null;
}

/** Plans one atomic Markdown table edit. Positions are JavaScript UTF-16 offsets. */
export function planMarkdownTableEdit(source: string, selection: TextRange, command: MarkdownTableEditingCommand): TextEditResult | null {
  const table = tableAt(source, selection);
  if (!table) return null;
  const count = columnCount(table), editable = table.rows.flatMap((_, row) => row === table.separatorRow ? [] : Array.from({ length: count }, (_, column) => ({ row, column })));
  if (command === "navigateForward" || command === "navigateBackward") {
    const current = editable.findIndex((cell) => cell.row === table.selectedRow && cell.column === table.selectedColumn);
    if (command === "navigateForward") {
      if (table.selectedRow === table.separatorRow) {
        const firstData = editable.find((cell) => cell.row > table.separatorRow);
        if (firstData) return selectionResult(source, table, firstData.row, firstData.column);
      } else if (current >= 0 && current + 1 < editable.length) return selectionResult(source, table, editable[current + 1].row, editable[current + 1].column);
      table.rows.push(blankRow(count)); return renderedResult(source, table, table.rows.length - 1, 0);
    }
    if (table.selectedRow === table.separatorRow) {
      const header = [...editable].reverse().find((cell) => cell.row < table.separatorRow);
      return header ? selectionResult(source, table, header.row, header.column) : null;
    }
    return current < 0 ? null : selectionResult(source, table, editable[Math.max(0, current - 1)].row, editable[Math.max(0, current - 1)].column);
  }
  if (command === "format") return renderedResult(source, table, table.selectedRow, table.selectedColumn, table.caretOffset);
  if (command === "insertRowAbove" || command === "insertRowBelow") {
    const at = table.selectedRow <= table.separatorRow ? table.separatorRow + 1 : command === "insertRowBelow" ? table.selectedRow + 1 : table.selectedRow;
    table.rows.splice(at, 0, blankRow(count)); return renderedResult(source, table, at, table.selectedColumn);
  }
  if (command === "deleteRow") {
    if (table.selectedRow <= table.separatorRow) return null;
    table.rows.splice(table.selectedRow, 1);
    return renderedResult(source, table, Math.min(Math.max(table.separatorRow + 1, table.selectedRow - 1), Math.max(0, table.rows.length - 1)), table.selectedColumn);
  }
  if (command === "insertColumnBefore" || command === "insertColumnAfter") {
    const at = Math.max(0, Math.min(count, table.selectedColumn + (command === "insertColumnAfter" ? 1 : 0)));
    table.rows.forEach((row, index) => { if (index !== table.separatorRow) { row.cells = padded(row.cells, count); row.cells.splice(at, 0, ""); } });
    table.alignments = paddedAlignments(table.alignments, count); table.alignments.splice(at, 0, "none");
    return renderedResult(source, table, table.selectedRow, at);
  }
  if (count <= 1) return null;
  const removed = table.selectedColumn;
  table.rows.forEach((row, index) => { if (index !== table.separatorRow) { row.cells = padded(row.cells, count); row.cells.splice(removed, 1); } });
  table.alignments = paddedAlignments(table.alignments, count); table.alignments.splice(removed, 1);
  return renderedResult(source, table, table.selectedRow, Math.min(removed, count - 2));
}

export const inspectMarkdownTableEditingContext = getMarkdownTableEditingContext;
