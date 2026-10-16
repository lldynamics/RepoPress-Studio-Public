import { describe, expect, it } from "vitest";
import type { DraftDiffLine } from "./draftHistory";
import { foldDraftDiffLines } from "./draftDiffRows";

const line = (kind: DraftDiffLine["kind"], index: number): DraftDiffLine => ({
  kind,
  text: `${kind}-${index}`,
  currentLine: index % 2 ? null : index + 1,
  historicalLine: index % 3 ? index + 1 : null,
});

const contexts = (count: number, offset = 0) => Array.from({ length: count }, (_, index) => line("context", offset + index));
const changed = (index: number): DraftDiffLine => line(index % 2 ? "removed" : "added", index);
const flatten = (rows: ReturnType<typeof foldDraftDiffLines>) => rows.flatMap((row) => row.kind === "line" ? [row.line] : row.lines);

describe("foldDraftDiffLines", () => {
  it.each([
    ["leading six", [...contexts(6), changed(6)], []],
    ["leading seven", [...contexts(7), changed(7)], [[0, 4]]],
    ["trailing six", [changed(0), ...contexts(6)], []],
    ["trailing seven", [changed(0), ...contexts(7, 1)], [[4, 8]]],
    ["interior nine", [changed(0), ...contexts(9, 1), changed(10)], []],
    ["interior ten", [changed(0), ...contexts(10, 1), changed(11)], [[4, 8]]],
    ["all context nine", contexts(9), []],
    ["all context ten", contexts(10), [[3, 7]]],
  ])("keeps the right boundary rows for %s", (_name, input, expectedRanges) => {
    const rows = foldDraftDiffLines(input as DraftDiffLine[]);
    expect(flatten(rows)).toEqual(input);
    expect(rows.filter((row) => row.kind === "fold").map((row) => [row.startIndex, row.endIndex])).toEqual(expectedRanges);
  });

  it("folds only long interior context runs and preserves changed rows", () => {
    const input = [changed(0), ...contexts(11, 1), changed(12), ...contexts(12, 13), changed(25)];
    const rows = foldDraftDiffLines(input);
    expect(rows.filter((row) => row.kind === "fold").map((row) => [row.startIndex, row.endIndex])).toEqual([[4, 9], [16, 22]]);
    expect(rows.filter((row) => row.kind === "line").map((row) => row.line.kind)).toContain("added");
    expect(flatten(rows)).toEqual(input);
  });

  it("does not fold adjacent changes, short runs, empty input, or unchanged short documents", () => {
    const input = [changed(0), changed(1), ...contexts(6, 2), changed(8), ...contexts(6, 9), changed(15)];
    expect(foldDraftDiffLines([])).toEqual([]);
    expect(foldDraftDiffLines(input).some((row) => row.kind === "fold")).toBe(false);
    expect(foldDraftDiffLines(contexts(6)).every((row) => row.kind === "line")).toBe(true);
  });

  it("keeps original references, frozen input and arbitrary line fields", () => {
    const input = Object.freeze([
      { kind: "context", text: "前", currentLine: null, historicalLine: null, raw: { brace: "}" } },
      ...contexts(10, 1),
      { kind: "added", text: "非ASCII 🚀", currentLine: null, historicalLine: null, raw: { brace: "{" } },
    ]) as readonly DraftDiffLine[];
    const rows = foldDraftDiffLines(input);
    expect(flatten(rows)).toEqual(input);
    expect(flatten(rows).every((value, index) => value === input[index])).toBe(true);
    const fold = rows.find((row) => row.kind === "fold");
    expect(fold?.kind === "fold" && fold.lines[0]).toBe(input[0]);
  });
});
