import { describe, expect, it } from "vitest";
import { getMarkdownTableEditingContext, planMarkdownTableEdit } from "./markdownTableEditing";

const at = (text: string, token: string, offset = 0) => ({ from: text.indexOf(token) + offset, to: text.indexOf(token) + offset });
const edit = (text: string, token: string, command: Parameters<typeof planMarkdownTableEdit>[2], offset = 0) => planMarkdownTableEdit(text, at(text, token, offset), command);

describe("markdown table editing", () => {
  it("finds table context and rejects ordinary text, fences, and a trailing newline cursor", () => {
    const text = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nEnd";
    expect(getMarkdownTableEditingContext(text, at(text, "1"))).toMatchObject({ rowIndex: 2, columnIndex: 0, isSeparatorRow: false, canDeleteRow: true, canDeleteColumn: true });
    expect(getMarkdownTableEditingContext(text, at(text, "Intro"))).toBeNull();
    const fenced = "```\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```";
    expect(getMarkdownTableEditingContext(fenced, at(fenced, "1"))).toBeNull();
    const ended = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";
    expect(getMarkdownTableEditingContext(ended, { from: ended.length, to: ended.length })).toBeNull();
  });

  it("ignores escaped and inline-code pipes while parsing", () => {
    const text = "| A \\| literal | `B|C` |\n| --- | --- |\n| x | y |";
    expect(getMarkdownTableEditingContext(text, at(text, "y"))?.columnIndex).toBe(1);
  });

  it("navigates cells, skips the separator, and materializes ragged cells", () => {
    const text = "| A | B |\n| --- | --- |\n| 1 | 2 |";
    const header = edit(text, "A", "navigateForward")!;
    expect(header.selection).toEqual({ from: text.indexOf("B"), to: text.indexOf("B") + 1 });
    const data = edit(text, "B", "navigateForward")!;
    expect(data.selection).toEqual({ from: text.indexOf("1"), to: text.indexOf("1") + 1 });
    const previous = edit(text, "1", "navigateBackward")!;
    expect(previous.selection).toEqual({ from: text.indexOf("B"), to: text.indexOf("B") + 1 });
    expect(edit(text, "2", "navigateForward")?.text).toBe("| A   | B   |\n| --- | --- |\n| 1   | 2   |\n|     |     |");
    const ragged = "| A | B |\n| --- | --- |\n| 1 |";
    expect(edit(ragged, "1", "navigateForward")?.text).toBe("| A   | B   |\n| --- | --- |\n| 1   |     |");
  });

  it("formats with alignment and maintains a UTF-16 caret", () => {
    const text = "|Name|Score|\n|:---|---:|\n|Ada|9|";
    const result = edit(text, "Ada", "format", 2)!;
    expect(result.text).toBe("| Name | Score |\n| :--- | ----: |\n| Ada  | 9     |");
    expect(result.selection).toEqual({ from: result.text.indexOf("Ada") + 2, to: result.text.indexOf("Ada") + 2 });
    const unicode = "| 名称 | 值 |\r\n| :--- | ---: |\r\n| 中文 | 1 |";
    expect(edit(unicode, "中文", "format", 1)?.text).toContain("| 名称 | 值  |");
  });

  it("inserts and deletes rows without allowing header or separator deletion", () => {
    const text = "| A | B |\n| --- | --- |\n| 1 | 2 |";
    expect(edit(text, "1", "insertRowAbove")?.text).toBe("| A   | B   |\n| --- | --- |\n|     |     |\n| 1   | 2   |");
    expect(edit(text, "1", "insertRowBelow")?.text).toBe("| A   | B   |\n| --- | --- |\n| 1   | 2   |\n|     |     |");
    expect(edit(text, "1", "deleteRow")?.text).toBe("| A   | B   |\n| --- | --- |");
    expect(edit(text, "A", "deleteRow")).toBeNull();
    expect(edit(text, "---", "deleteRow")).toBeNull();
  });

  it("inserts and deletes columns while retaining one column and CRLF/no trailing newline", () => {
    const text = "| A | B |\n| --- | --- |\n| 1 | 2 |";
    expect(edit(text, "B", "insertColumnBefore")?.text).toBe("| A   |     | B   |\n| --- | --- | --- |\n| 1   |     | 2   |");
    expect(edit(text, "B", "deleteColumn")?.text).toBe("| A   |\n| --- |\n| 1   |");
    const one = "| A |\n| --- |\n| 1 |";
    expect(edit(one, "A", "deleteColumn")).toBeNull();
    const crlf = "before\r\n| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\nafter";
    expect(edit(crlf, "1", "format")?.text).toContain("| A   | B   |\r\n| --- | --- |\r\n| 1   | 2   |");
  });
});
