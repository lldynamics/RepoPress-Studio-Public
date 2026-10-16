import { describe, expect, it } from "vitest";
import { applyMarkdownFormat, findMatches, findNextMatch, getMarkdownOutline, getWritingStats, inspectMatches, planMarkdownListContinuation, replaceAll, replaceCurrentOrNext } from "./markdownWriting";

describe("markdown writing model", () => {
  it("wraps and toggles an inline selection without mutating the source", () => {
    expect(applyMarkdownFormat("hello", { from: 0, to: 5 }, "bold")).toEqual({ text: "**hello**", selection: { from: 0, to: 9 } });
    expect(applyMarkdownFormat("**hello**", { from: 0, to: 9 }, "bold")).toEqual({ text: "hello", selection: { from: 0, to: 5 } });
    expect(applyMarkdownFormat("", { from: 0, to: 0 }, "italic")).toEqual({ text: "*斜体*", selection: { from: 1, to: 3 } });
  });
  it("formats lines and preserves a valid selection", () => {
    const result = applyMarkdownFormat("one\ntwo", { from: 0, to: 7 }, "unorderedList");
    expect(result.text).toBe("- one\n- two"); expect(result.selection.from).toBe(0); expect(result.selection.to).toBe(result.text.length);
  });
  it("ignores fenced headings in the outline and calculates stats", () => {
    expect(getMarkdownOutline("# Intro\n```\n## hidden\n```\n### Details")).toEqual([
      { level: 1, title: "Intro", line: 1, from: 2, to: 7 },
      { level: 3, title: "Details", line: 5, from: 30, to: 37 },
    ]);
    expect(getWritingStats("one two\nthree")).toEqual({ words: 3, characters: 13, lines: 2, readingMinutes: 1 });
    expect(getWritingStats("你好 world 👋")).toEqual({ words: 3, characters: 10, lines: 1, readingMinutes: 1 });
    expect(getWritingStats("中文 e\u0301clair alpha-2")).toEqual({ words: 5, characters: 18, lines: 1, readingMinutes: 1 });
    expect(getWritingStats("你".repeat(501))).toMatchObject({ words: 501, readingMinutes: 2 });
  });
  it("handles safe, bounded, case-aware search and replace", () => {
    expect(findMatches("Cat cat", "cat")).toEqual([{ from: 0, to: 3 }, { from: 4, to: 7 }]);
    expect(findNextMatch("a b a", "a", 1, "next")).toEqual({ from: 4, to: 5 });
    expect(findNextMatch("a b a", "a", 4, "previous")).toEqual({ from: 0, to: 1 });
    expect(replaceAll("Cat cat", "cat", "dog", { caseSensitive: true }).text).toBe("Cat dog");
    expect(replaceAll("abc", "", "x").text).toBe("abc");
    expect(findMatches("cat scatter cat", "cat", { wholeWord: true })).toEqual([{ from: 0, to: 3 }, { from: 12, to: 15 }]);
    expect(findMatches("café caféine café", "café", { wholeWord: true })).toEqual([{ from: 0, to: 4 }, { from: 13, to: 17 }]);
    expect(findMatches("e\u0301clair e", "e", { wholeWord: true })).toEqual([{ from: 8, to: 9 }]);
    expect(findMatches("中文中文 中文", "中文", { wholeWord: true })).toEqual([{ from: 5, to: 7 }]);
    expect(inspectMatches("abc", "(", { regularExpression: true }).error).toBe("正则表达式无效");
  });
  it("expands regular-expression replacements but keeps plain replacements literal", () => {
    expect(replaceAll("ab-12 cd-34", "([a-z]+)-(\\d+)", "$2:$1/$&/$0/$$", { regularExpression: true }).text).toBe("12:ab/ab-12/ab-12/$ 34:cd/cd-34/cd-34/$");
    expect(replaceAll("a a", "a", "$1 $$ $&").text).toBe("$1 $$ $& $1 $$ $&");
    expect(replaceAll("a", "(", "x", { regularExpression: true })).toMatchObject({ text: "a", replacementCount: 0 });
  });
  it("replaces an exact current selection or the next match with wrap feedback", () => {
    expect(replaceCurrentOrNext("a b a", "a", "x", { from: 0, to: 1 })).toMatchObject({ text: "x b a", selection: { from: 0, to: 1 }, replacementCount: 1, index: 0, total: 2, wrapped: false });
    expect(replaceCurrentOrNext("a b a", "a", "x", { from: 2, to: 2 })).toMatchObject({ text: "a b x", selection: { from: 4, to: 5 }, index: 1, wrapped: false });
    expect(replaceCurrentOrNext("a b a", "a", "x", { from: 5, to: 5 })).toMatchObject({ text: "x b a", index: 0, wrapped: true });
    // A stale range no longer matches after its text changed, so the next live
    // result is used rather than replacing the old range blindly.
    expect(replaceCurrentOrNext("z b a", "a", "x", { from: 0, to: 1 })).toMatchObject({ text: "z b x", index: 0 });
  });
  it("handles zero-width matches without looping and reports replacement totals", () => {
    expect(replaceAll("ab", "(?=.)", "_", { regularExpression: true })).toMatchObject({ text: "_a_b", replacementCount: 2 });
  });
  it("continues and exits Markdown lists", () => {
    expect(planMarkdownListContinuation("1. first", 8)).toEqual({ text: "1. first\n2. ", selection: { from: 12, to: 12 } });
    expect(planMarkdownListContinuation("- [x] done", 10)).toEqual({ text: "- [x] done\n- [ ] ", selection: { from: 17, to: 17 } });
    expect(planMarkdownListContinuation("1、第一项", 5)).toEqual({ text: "1、第一项\n2、", selection: { from: 8, to: 8 } });
    expect(planMarkdownListContinuation("9、 第九项", 6)).toEqual({ text: "9、 第九项\n10、 ", selection: { from: 11, to: 11 } });
    expect(planMarkdownListContinuation("> 引用", 4)).toEqual({ text: "> 引用\n> ", selection: { from: 7, to: 7 } });
    expect(planMarkdownListContinuation("- ", 2)).toEqual({ text: "", selection: { from: 0, to: 0 } });
    expect(planMarkdownListContinuation("1、第一项\n2、", 9)).toEqual({ text: "1、第一项\n", selection: { from: 6, to: 6 } });
    expect(planMarkdownListContinuation("```\n- code", 10)).toBeNull();
  });
});
