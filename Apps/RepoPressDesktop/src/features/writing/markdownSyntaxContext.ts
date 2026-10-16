export type MarkdownFenceMarker = "`" | "~";

export interface MarkdownFenceState {
  marker: MarkdownFenceMarker | null;
  length: number;
}

export interface MarkdownFenceTransition {
  state: MarkdownFenceState;
  delimiterLine: boolean;
}

export function markdownFrontMatterBodyOffset(source: string): number {
  const firstEnd = source.indexOf("\n");
  const first = source.slice(0, firstEnd < 0 ? source.length : firstEnd).replace(/\r$/, "");
  const opening = first.match(/^(---|\+\+\+)[ \t]*$/)?.[1] as "---" | "+++" | undefined;
  if (!opening) return 0;
  if (firstEnd < 0) return Number.POSITIVE_INFINITY;

  let offset = firstEnd + 1;
  while (offset <= source.length) {
    const end = source.indexOf("\n", offset);
    const lineEnd = end < 0 ? source.length : end;
    const line = source.slice(offset, lineEnd).replace(/\r$/, "");
    const closes = opening === "---"
      ? /^(?:---|\.\.\.)[ \t]*$/.test(line)
      : /^\+\+\+[ \t]*$/.test(line);
    if (closes) return end < 0 ? source.length : end + 1;
    if (end < 0) break;
    offset = end + 1;
  }
  return Number.POSITIVE_INFINITY;
}

export function transitionMarkdownFence(line: string, current: MarkdownFenceState): MarkdownFenceTransition {
  const match = line.match(/^ {0,3}(`{3,}|~{3,})/);
  if (!match) return { state: current, delimiterLine: false };
  const marker = match[1][0] as MarkdownFenceMarker;
  const length = match[1].length;

  if (!current.marker) {
    return { state: { marker, length }, delimiterLine: true };
  }
  const remainder = line.slice(match[0].length);
  if (marker === current.marker && length >= current.length && /^[ \t]*$/.test(remainder)) {
    return { state: { marker: null, length: 0 }, delimiterLine: true };
  }
  return { state: current, delimiterLine: false };
}

export function isInsideMarkdownFence(source: string, lineStart: number, bodyOffset: number, currentLinePrefix = ""): boolean {
  let state: MarkdownFenceState = { marker: null, length: 0 };
  for (const line of source.slice(bodyOffset, lineStart).split(/\r?\n/)) {
    state = transitionMarkdownFence(line, state).state;
  }
  if (state.marker) return true;
  return transitionMarkdownFence(currentLinePrefix, state).delimiterLine;
}

export function isMarkdownEscaped(source: string, index: number): boolean {
  let slashes = 0;
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === "\\"; cursor -= 1) slashes += 1;
  return slashes % 2 === 1;
}

export function isInsideMarkdownInlineCode(prefix: string): boolean {
  let delimiterLength = 0;
  for (let index = 0; index < prefix.length;) {
    if (prefix[index] !== "`" || isMarkdownEscaped(prefix, index)) { index += 1; continue; }
    let end = index + 1;
    while (prefix[end] === "`") end += 1;
    const runLength = end - index;
    if (!delimiterLength) delimiterLength = runLength;
    else if (runLength === delimiterLength) delimiterLength = 0;
    index = end;
  }
  return delimiterLength > 0;
}
