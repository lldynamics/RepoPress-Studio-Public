import { describe, expect, it } from "vitest";
import { counterpartMarkdownFence, goToMarkdownLine, markdownCursorPosition, markdownFenceContexts } from "./markdownCursorWorkflow";

describe("markdown cursor workflow", () => {
  it("uses CodeMirror UTF-16 offsets while displaying Unicode columns", () => {
    const source = "😀中a\n下一行";
    expect(markdownCursorPosition(source, { from: 3, to: 3 })).toMatchObject({ line: 1, column: 3, utf16Column: 4 });
    expect(markdownCursorPosition(source, { from: 999, to: -2 })).toMatchObject({ line: 2, column: 4, utf16Column: 4 });
  });
  it("handles CRLF and a trailing empty line", () => {
    const source = "one\r\ntwo\r\n";
    expect(goToMarkdownLine(source, "3").range).toEqual({ from: source.length, to: source.length });
    expect(markdownCursorPosition(source, { from: 5, to: 5 }).line).toBe(2);
  });
  it("rejects blank, non-integer and out of range lines", () => {
    expect(goToMarkdownLine("a\nb", "").error).toBeTruthy();
    expect(goToMarkdownLine("a\nb", "1.5").error).toBeTruthy();
    expect(goToMarkdownLine("a\nb", "3").error).toBeTruthy();
  });
  it("ignores front matter and requires matching fence marker and length", () => {
    const source = "---\n```\n---\n正文\n~~~js\n内容\n~~~~\n";
    const fences = markdownFenceContexts(source);
    expect(fences).toHaveLength(1); expect(fences[0].marker).toBe("~"); expect(fences[0].isClosed).toBe(true);
  });
  it("finds closed and unclosed fences, without inventing a closing endpoint", () => {
    const closed = "```js\ncode\n```"; const match = markdownFenceContexts(closed)[0];
    expect(match.closingLine).toBe(3);
    expect(counterpartMarkdownFence(closed, { from: 0, to: 0 })).toEqual(match.closing);
    const open = "~~~\ncode"; const openMatch = markdownFenceContexts(open)[0];
    expect(openMatch.closing).toBeNull(); expect(counterpartMarkdownFence(open, { from: 5, to: 5 })).toEqual(openMatch.opening);
  });
});
