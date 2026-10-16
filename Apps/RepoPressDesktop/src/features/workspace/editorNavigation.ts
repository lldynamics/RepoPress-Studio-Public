export type EditorLocation =
  | { kind: "search"; lineNumber: number; snippet: string; query: string }
  | { kind: "range"; range: { from: number; to: number }; expectedText: string };

interface SourceLine {
  from: number;
  to: number;
}

/**
 * Resolves persisted editor targets only when their original search/range
 * snapshot remains valid. Offsets are JavaScript UTF-16 code-unit offsets.
 */
export function resolveEditorLocation(text: string, location: EditorLocation): { from: number; to: number } | null {
  if (location.kind === "range") return resolveRange(text, location.range, location.expectedText);
  return resolveSearch(text, location);
}

function resolveRange(text: string, range: { from: number; to: number }, expectedText: string): { from: number; to: number } | null {
  const { from, to } = range;
  if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || from < 0 || to < from || to > text.length) return null;
  return text === expectedText ? { from, to } : null;
}

function resolveSearch(text: string, location: Extract<EditorLocation, { kind: "search" }>): { from: number; to: number } | null {
  if (!Number.isSafeInteger(location.lineNumber) || location.lineNumber < 1) return null;
  const query = location.query.trim();
  if (!query) return null;

  const line = rustLineAt(text, location.lineNumber);
  if (!line) return null;
  const contentFrom = line.from === 0 && text.charCodeAt(0) === 0xFEFF ? 1 : line.from;
  const source = text.slice(contentFrom, line.to);
  if (boundedSnippet(source) !== location.snippet) return null;

  const range = foldedMatchRange(source, query);
  return range ? { from: contentFrom + range.from, to: contentFrom + range.to } : null;
}

/** Mirrors Rust str::lines(): LF and CRLF end a line; a terminal LF adds no line. */
function rustLineAt(text: string, lineNumber: number): SourceLine | null {
  let line = 1;
  let from = 0;
  while (from < text.length) {
    const newline = text.indexOf("\n", from);
    const newlineEnd = newline < 0 ? text.length : newline;
    const to = newline > from && text.charCodeAt(newline - 1) === 0x0D ? newline - 1 : newlineEnd;
    if (line === lineNumber) return { from, to };
    if (newline < 0) return null;
    from = newline + 1;
    line += 1;
  }
  return null;
}

function boundedSnippet(line: string): string {
  return Array.from(line.replace(/[\r\n]/g, " ")).slice(0, 240).join("");
}

/**
 * Finds a match in the whole line, then maps only complete lower-case scalar
 * segments back to source offsets. This prevents a match inside an expanded
 * case mapping from selecting a misleading partial UTF-16 range.
 */
function foldedMatchRange(source: string, query: string): { from: number; to: number } | null {
  const foldedSource = source.toLowerCase();
  const foldedQuery = query.toLowerCase();
  const matchFrom = foldedSource.indexOf(foldedQuery);
  if (matchFrom < 0) return null;
  const matchTo = matchFrom + foldedQuery.length;
  const boundaries = foldedBoundaries(source);
  const from = boundaries.get(matchFrom);
  const to = boundaries.get(matchTo);
  return from === undefined || to === undefined ? null : { from, to };
}

function foldedBoundaries(source: string): Map<number, number> {
  const boundaries = new Map<number, number>();
  let sourceOffset = 0;
  let foldedOffset = 0;
  boundaries.set(0, 0);
  for (const character of source) {
    sourceOffset += character.length;
    foldedOffset += character.toLowerCase().length;
    boundaries.set(foldedOffset, sourceOffset);
  }
  return boundaries;
}
