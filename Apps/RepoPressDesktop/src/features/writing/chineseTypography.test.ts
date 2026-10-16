import { describe, expect, it } from "vitest";
import { formatChineseTypography, planChineseTypography } from "./chineseTypography";

describe("formatChineseTypography", () => {
  it("adds one space between CJK prose and ASCII letters or digits", () => {
    expect(formatChineseTypography("使用Mac版编辑器开发Swift应用，在2026年完成100篇博客。日本語React韓国어2"))
      .toBe("使用 Mac 版编辑器开发 Swift 应用，在 2026 年完成 100 篇博客。日本語 React 韓国어 2");
  });

  it("removes inappropriate spaces around full-width punctuation and cleans whitespace", () => {
    expect(formatChineseTypography("你好 ， 世界 ！ 这是 《 Swift 进阶 》 。  \n\n\n\n第二段\t"))
      .toBe("你好，世界！这是《Swift 进阶》。\n\n第二段");
  });

  it("preserves initial front matter but formats the document body", () => {
    const source = "---\ntitle: 我的Swift6博客\ntags: [Swift, Mac]\n---\n欢迎阅读这篇Blog文章。";
    expect(formatChineseTypography(source)).toBe("---\ntitle: 我的Swift6博客\ntags: [Swift, Mac]\n---\n欢迎阅读这篇 Blog 文章。");
  });

  it("preserves a closed fence immediately following front matter", () => {
    const source = "---\ntitle: 中文React\n---\n```ts\nconst label = '中文English';\n```\n正文React。";
    expect(formatChineseTypography(source))
      .toBe("---\ntitle: 中文React\n---\n```ts\nconst label = '中文English';\n```\n正文 React。");
  });

  it("leaves an unclosed front matter region byte-for-byte unchanged, including nested fences and placeholders", () => {
    const source = "---\ntitle: 中文React\n```ts\nconst label = '中文English';\n```\n\uE000repo-press-chinese-typography-0-0\uE001正文Vue";
    expect(formatChineseTypography(source)).toBe(source);
  });

  it("preserves closed and unclosed fenced code blocks", () => {
    expect(formatChineseTypography("正文Swift。\n```swift\nconst x = '中文English';\n```\n外部React。"))
      .toBe("正文 Swift。\n```swift\nconst x = '中文English';\n```\n外部 React。");
    expect(formatChineseTypography("正文Swift。\n~~~ts\nconst x = '中文English';\n尾部React。"))
      .toBe("正文 Swift。\n~~~ts\nconst x = '中文English';\n尾部React。");
  });

  it("preserves display math, inline code, HTML, link destinations, and SSG fragments", () => {
    const source = "正文Swift，$$ 中文English $$，`中文Code`，<Badge title=\"中文React\" />，[React官网](https://x.test/中文React?a=(b))，{{< note title=\"中文React\" >}}，{% include 中文React %}。";
    expect(formatChineseTypography(source))
      .toBe("正文 Swift，$$ 中文English $$，`中文Code`，<Badge title=\"中文React\" />，[React 官网](https://x.test/中文React?a=(b))，{{< note title=\"中文React\" >}}，{% include 中文React %}。");
  });

  it("uses placeholders that cannot collide with original prose", () => {
    const source = "\uE000repo-press-chinese-typography-0-0\uE001中文React，`中文Code`";
    expect(formatChineseTypography(source)).toBe("\uE000repo-press-chinese-typography-0-0\uE001中文 React，`中文Code`");
    const nestedCollision = "---\ntitle: \uE000repo-press-chinese-typography-1-0\uE001中文React\n---\n正文React，`中文Code`";
    expect(formatChineseTypography(nestedCollision))
      .toBe("---\ntitle: \uE000repo-press-chinese-typography-1-0\uE001中文React\n---\n正文 React，`中文Code`");
  });

  it("preserves CRLF while collapsing blank lines", () => {
    expect(formatChineseTypography("中文React  \r\n\r\n\r\n\r\n下一段Vue\r\n"))
      .toBe("中文 React\r\n\r\n下一段 Vue\r\n");
  });
});

describe("planChineseTypography", () => {
  it("formats the entire document for an empty selection and returns null for a no-op", () => {
    expect(planChineseTypography("中文React", { from: 2, to: 2 })).toEqual({ text: "中文 React", selection: { from: 0, to: 0 } });
    expect(planChineseTypography("中文 React", { from: 0, to: 0 })).toBeNull();
    expect(planChineseTypography("", { from: 0, to: 0 })).toBeNull();
  });

  it("formats only a non-empty UTF-16 selection, including one after an emoji", () => {
    const source = "前😀中文React后Swift";
    const selected = source.indexOf("中文React");
    expect(selected).toBe(3);
    expect(planChineseTypography(source, { from: selected, to: selected + "中文React".length }))
      .toEqual({ text: "前😀中文 React后Swift", selection: { from: 3, to: 11 } });
  });

  it("clamps reverse selections using UTF-16 offsets and leaves surrounding text alone", () => {
    expect(planChineseTypography("甲React乙Vue丙", { from: 7, to: 1 }))
      .toEqual({ text: "甲React 乙Vue丙", selection: { from: 1, to: 8 } });
  });
});
