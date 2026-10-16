import type { DraftDiffLine } from "./draftHistory";

export type DraftDiffRow =
  | { kind: "line"; index: number; line: DraftDiffLine }
  | { kind: "fold"; id: string; startIndex: number; endIndex: number; lines: readonly DraftDiffLine[] };

/** Present context runs with three surrounding lines and at least four hidden lines. */
export function foldDraftDiffLines(lines: readonly DraftDiffLine[]): DraftDiffRow[] {
  const rows: DraftDiffRow[] = [];
  let index = 0;

  while (index < lines.length) {
    if (lines[index].kind !== "context") {
      rows.push({ kind: "line", index, line: lines[index] });
      index += 1;
      continue;
    }

    const startIndex = index;
    while (index < lines.length && lines[index].kind === "context") index += 1;
    const endIndex = index;
    const hasPreviousChange = startIndex > 0;
    const hasNextChange = endIndex < lines.length;

    let hiddenStart = startIndex;
    let hiddenEnd = endIndex;
    if (hasPreviousChange && hasNextChange) {
      hiddenStart += 3;
      hiddenEnd -= 3;
    } else if (hasPreviousChange) {
      hiddenStart += 3;
    } else if (hasNextChange) {
      hiddenEnd -= 3;
    } else {
      hiddenStart += 3;
      hiddenEnd -= 3;
    }

    if (hiddenEnd - hiddenStart < 4) {
      hiddenStart = endIndex;
      hiddenEnd = endIndex;
    }
    for (let lineIndex = startIndex; lineIndex < hiddenStart; lineIndex += 1) {
      rows.push({ kind: "line", index: lineIndex, line: lines[lineIndex] });
    }
    if (hiddenStart < hiddenEnd) {
      rows.push({
        kind: "fold",
        id: `${hiddenStart}:${hiddenEnd}`,
        startIndex: hiddenStart,
        endIndex: hiddenEnd,
        lines: lines.slice(hiddenStart, hiddenEnd),
      });
    }
    for (let lineIndex = hiddenEnd; lineIndex < endIndex; lineIndex += 1) {
      rows.push({ kind: "line", index: lineIndex, line: lines[lineIndex] });
    }
  }

  return rows;
}
