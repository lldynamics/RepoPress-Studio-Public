import { describe, expect, it } from "vitest";
import { applyMarkdownDiagnosticFix, getMarkdownDiagnostics } from "./markdownDiagnostics";

const byId = (source: string, id: string) => getMarkdownDiagnostics(source).find((item) => item.id.startsWith(id));

describe("markdown diagnostics", () => {
  it("honors an explicit caller-owned issue bound", () => {
    expect(getMarkdownDiagnostics("https://a.test\nhttps://b.test", { maxIssues: 1 })).toHaveLength(1);
    expect(getMarkdownDiagnostics("https://a.test", { maxIssues: 0 })).toEqual([]);
  });
  it("accepts a caller-owned normalized wiki target index", () => {
    expect(getMarkdownDiagnostics("[[Known]]", { normalizedKnownArticleTitles: new Set(["known"]) })).toEqual([]);
    expect(getMarkdownDiagnostics("[[Missing]]", { normalizedKnownArticleTitles: new Set(["known"]) })[0]?.id)
      .toMatch(/^missing-internal-link-/);
  });
  it("reports empty image alt text and safely suggests a filename-derived replacement", () => {
    const source = "前言\n![](images/海报-one.png)";
    const item = byId(source, "image-alt")!;
    expect(item).toMatchObject({ severity: "warning", title: "图片缺少 alt 文本", range: { from: 4, to: 6 }, expectedText: "[]", replacement: "[海报 one]" });
    expect(applyMarkdownDiagnosticFix(source, item)?.text).toContain("![海报 one](images/海报-one.png)");
  });

  it("detects heading jumps and duplicate headings, with a narrow safe jump fix", () => {
    const source = "# 总览\n### 细节\n## 总览";
    const items = getMarkdownDiagnostics(source);
    expect(items.map((item) => item.title)).toEqual(["标题层级跳跃", "标题重复"]);
    const jump = items[0];
    expect(jump.range).toEqual({ from: 5, to: 8 });
    expect(applyMarkdownDiagnosticFix(source, jump)?.text).toContain("## 细节");
    expect(items[1]).toMatchObject({
      message: "与第 1 行的标题重复，建议使用更具体的章节名。",
      related: { range: { from: 0, to: 4 }, line: 1 },
      presentation: { message: { parameters: { line: 1 } } },
    });
    expect(items[1].replacement).toBeUndefined();
    expect(items[1].expectedText).toBeUndefined();
    expect(applyMarkdownDiagnosticFix(source, items[1])).toBeNull();
  });

  it("uses original inline heading text and conservative Unicode normalization", () => {
    const source = [
      "# API `foo`",
      "# API `bar`",
      "# API `foo`",
      "# ＡＰＩ   使用",
      "# api 使用",
      "# name_with_value",
      "# namewithvalue",
      "# *literal*",
      "# literal",
      "# 转义 \\*星号\\*",
      "# 转义 *星号*",
    ].join("\n");
    const duplicates = getMarkdownDiagnostics(source).filter((item) => item.id.startsWith("duplicate-heading"));
    expect(duplicates).toHaveLength(2);
    expect(duplicates.map((item) => item.related?.line)).toEqual([1, 4]);
    expect(duplicates.map((item) => source.slice(item.range.from, item.range.to))).toEqual(["# API `foo`", "# api 使用"]);
  });

  it("keeps C# literal while honoring whitespace-delimited ATX closing hashes", () => {
    const source = "# C#\n# C\n# Topic ###\n# topic #\n# Escaped \\#\n# Escaped #";
    const duplicates = getMarkdownDiagnostics(source).filter((item) => item.id.startsWith("duplicate-heading"));
    expect(duplicates.map((item) => source.slice(item.range.from, item.range.to))).toEqual(["# topic #"]);
    expect(duplicates[0].related?.line).toBe(3);
  });

  it("does not report repeated empty ATX headings as named duplicates", () => {
    const source = "# ###\r\n# ###\r\n# #\n# #\n# ##\n# ##\n#\n#\n# C#\n# C#\n# Title###\n# Title###";
    const duplicates = getMarkdownDiagnostics(source).filter((item) => item.id.startsWith("duplicate-heading"));
    expect(duplicates.map((item) => source.slice(item.range.from, item.range.to))).toEqual(["# C#", "# Title###"]);
  });

  it("relates every later occurrence to the first heading with UTF-16 and CRLF-safe ranges", () => {
    const source = "# 😀 标题\r\n正文\r\n## 😀 标题\r\n### 😀 标题";
    const duplicates = getMarkdownDiagnostics(source).filter((item) => item.id.startsWith("duplicate-heading"));
    expect(duplicates).toHaveLength(2);
    expect(duplicates.map((item) => item.related)).toEqual([
      { range: { from: 0, to: 8 }, line: 1 },
      { range: { from: 0, to: 8 }, line: 1 },
    ]);
    expect(duplicates.map((item) => source.slice(item.range.from, item.range.to))).toEqual(["## 😀 标题\r", "### 😀 标题"]);
  });

  it("excludes fake headings in malformed front matter, fenced and indented code, comments, and HTML blocks", () => {
    const malformedFrontMatter = "---\n# 元数据\n# 元数据";
    expect(getMarkdownDiagnostics(malformedFrontMatter).filter((item) => item.id.startsWith("duplicate-heading"))).toEqual([]);

    const excluded = [
      "```md",
      "# 围栏",
      "# 围栏",
      "```",
      "    # 缩进代码",
      "    # 缩进代码",
      "<!--",
      "# 注释",
      "# 注释",
      "-->",
      "<div>",
      "# HTML",
      "# HTML",
      "</div>",
      "",
      "# 正文",
      "# 正文",
    ].join("\n");
    const duplicates = getMarkdownDiagnostics(excluded).filter((item) => item.id.startsWith("duplicate-heading"));
    expect(duplicates).toHaveLength(1);
    expect(excluded.slice(duplicates[0].range.from, duplicates[0].range.to)).toBe("# 正文");

    const closedFrontMatter = [
      "---",
      "title: ok",
      "---",
      "# 正文",
      "# 正文",
    ].join("\n");
    expect(getMarkdownDiagnostics(closedFrontMatter).filter((item) => item.id.startsWith("duplicate-heading"))).toHaveLength(1);
  });

  it("does not let inline code open an HTML comment block", () => {
    const source = "`<!--`\n# 正文\n# 正文\n# `<!--`\n# `<!--`";
    const duplicates = getMarkdownDiagnostics(source).filter((item) => item.id.startsWith("duplicate-heading"));
    expect(duplicates).toHaveLength(2);
    expect(duplicates.map((item) => item.related?.line)).toEqual([2, 4]);
  });

  it("uses raw HTML lines to close pre blocks even when the terminator is wrapped in backticks", () => {
    const source = "<pre>\n```\n`</pre>`\n# 正文\n# 正文";
    const duplicates = getMarkdownDiagnostics(source).filter((item) => item.id.startsWith("duplicate-heading"));
    expect(duplicates).toHaveLength(1);
    expect(duplicates[0].related?.line).toBe(4);
  });

  it("keeps duplicate diagnostics source ordered and applies maxIssues after ordering", () => {
    const source = "# 一\n# 一\n![](later.png)\n# 二\n# 二\n# 二";
    const all = getMarkdownDiagnostics(source);
    expect(all.map((item) => item.id.split("-").slice(0, -1).join("-"))).toEqual([
      "duplicate-heading",
      "image-alt",
      "duplicate-heading",
      "duplicate-heading",
    ]);
    const bounded = getMarkdownDiagnostics(source, { maxIssues: 1 });
    expect(bounded.map((item) => item.id.split("-").slice(0, -1).join("-"))).toEqual(["duplicate-heading"]);
  });

  it("finds undefined footnotes while accepting a definition", () => {
    const source = "有定义[^one]，无定义[^二]。\n\n[^one]: 内容";
    const items = getMarkdownDiagnostics(source);
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ severity: "error", title: "脚注没有定义" });
    expect(source.slice(items[0].range.from, items[0].range.to)).toBe("[^二]");
  });

  it("wraps bare URLs, but does not flag Markdown destinations or autolinks", () => {
    const source = "见 https://example.com/a。 [站点](https://example.com/b) <https://example.com/c>";
    const item = byId(source, "bare-url")!;
    expect(item.replacement).toBe("[链接](https://example.com/a)");
    expect(getMarkdownDiagnostics(source).filter((item) => item.id.startsWith("bare-url"))).toHaveLength(1);
  });

  it("adds a missing space after a Chinese ordered-list marker", () => {
    const source = "  1、第一项\n2、 第二项";
    const item = byId(source, "ordered-list-space")!;
    expect(source.slice(item.range.from, item.range.to)).toBe("1、");
    expect(applyMarkdownDiagnosticFix(source, item)?.text).toBe("  1、 第一项\n2、 第二项");
  });

  it("reports an unclosed fenced code block without attempting a speculative fix", () => {
    const source = "正文\n```ts\nconst x = 1;";
    const item = byId(source, "unclosed-code-fence")!;
    expect(item).toMatchObject({ severity: "error", title: "代码围栏没有闭合" });
    expect(item.replacement).toBeUndefined();
    expect(applyMarkdownDiagnosticFix(source, item)).toBeNull();
  });

  it("normalizes wiki titles for case, extensions, fragments, paths, and aliases", () => {
    const source = "[[HELLO world.md#第一节]] [[docs/安装指南|安装]] [[不存在]]";
    const items = getMarkdownDiagnostics(source, { knownArticleTitles: ["Hello World", "安装指南.md"] });
    expect(items).toHaveLength(1);
    expect(items[0].title).toBe("内部链接目标不存在");
    expect(source.slice(items[0].range.from, items[0].range.to)).toBe("[[不存在]]");
  });

  it("keeps source ordering and UTF-16 offsets, and ignores front matter and code", () => {
    const source = "---\ntitle: https://ignored.example\n---\n`![](x) https://ignored.example [[no]]`\n```md\n![](x)\nhttps://ignored.example\n[[no]]\n```\n😀 ![](real.png)\nhttps://real.example";
    const items = getMarkdownDiagnostics(source, { knownArticleTitles: [] });
    expect(items.map((item) => item.id.split("-").slice(0, -1).join("-"))).toEqual(["image-alt", "bare-url"]);
    expect(items[0].range.from).toBe(source.indexOf("![](real.png)") + 1);
    expect(items[1].range.from).toBe(source.lastIndexOf("https://real.example"));
    expect(items[0].range.from).toBeGreaterThan(source.indexOf("😀"));
  });

  it("does not diagnose heading, footnote, list, image, URL, or wiki-like text inside front matter and code", () => {
    const source = "---\n# 重复\n# 重复\n[^坏]\n1、项目\n![](bad.png)\nhttps://bad.example\n[[不存在]]\n---\n`# 重复 [^坏] 1、项目 ![](bad.png) https://bad.example [[不存在]]`\n```md\n# 重复\n# 重复\n[^坏]\n1、项目\n![](bad.png)\nhttps://bad.example\n[[不存在]]\n```";
    expect(getMarkdownDiagnostics(source, { knownArticleTitles: ["存在"] })).toEqual([]);
  });

  it("rejects stale diagnostics instead of overwriting newer text", () => {
    const source = "https://example.com";
    const item = byId(source, "bare-url")!;
    expect(applyMarkdownDiagnosticFix("https://changed.example", item)).toBeNull();
  });
});
