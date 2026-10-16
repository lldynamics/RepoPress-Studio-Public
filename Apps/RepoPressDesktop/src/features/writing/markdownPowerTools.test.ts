import { describe, expect, it } from "vitest";
import { applyMarkdownIndent, applySlashCommand, deleteMarkdownSection, duplicateMarkdownSection, findSlashQuery, getMarkdownSectionAnchor, getMarkdownSections, getSlashCommands, moveMarkdownSection } from "./markdownPowerTools";

describe("markdown power tools", () => {
  it("finds and applies a slash command at the current line", () => {
    expect(findSlashQuery("正文\n/标", 5)).toEqual({ from: 3, to: 5, query: "标" });
    const result = applySlashCommand("/二", 2, "heading-2");
    expect(result?.text).toBe("## ");
    expect(result?.selection).toEqual({ from: 3, to: 3 });
    expect(result?.triggerRange).toEqual({ from: 0, to: 2 });
    expect(applySlashCommand("/三", 2, "heading-3", "二")).toBeNull();
    expect(applySlashCommand("正文", 2, "heading-2")).toBeNull();
  });

  it("filters discoverable Chinese commands and handles no results", () => {
    expect(getSlashCommands("任务").map((command) => command.id)).toContain("task-list");
    expect(getSlashCommands("ｔａｂｌｅ").map((command) => command.id)).toContain("table");
    expect(getSlashCommands("不存在")).toEqual([]);
  });

  it("does not open inside fenced or inline code and numbers footnotes", () => {
    expect(findSlashQuery("```\n/标题", 7)).toBeNull();
    expect(findSlashQuery("`/标题", 4)).toBeNull();
    const result = applySlashCommand("[^1] 内容\n/脚", 10, "footnote");
    expect(result?.text).toContain("[^2]\n\n[^2]: ");
    const image = applySlashCommand("/图片", 3, "image");
    expect(image?.text).toBe("![图片说明](images/)");
    expect(image?.text.slice(image.selection.from, image.selection.to)).toBe("图片说明");
  });

  it("does not open slash commands inside YAML or TOML front matter", () => {
    expect(findSlashQuery("---\n/标题\n---\n正文", 6)).toBeNull();
    expect(findSlashQuery("+++\n/标题\n+++\n正文", 6)).toBeNull();
    expect(findSlashQuery("+++\ntitle = 'x'\n+++\n/标题", 24)?.query).toBe("标题");
    const malformedFrontMatter = "---\ntitle: x\n---oops\n/标题\n---";
    expect(findSlashQuery(malformedFrontMatter, malformedFrontMatter.indexOf("\n---", 14))).toBeNull();
    const mixedFence = "```js\n~~~\n/标题";
    expect(findSlashQuery(mixedFence, mixedFence.length)).toBeNull();
    const trailingFence = "```js\n```still-code\n/标题";
    expect(findSlashQuery(trailingFence, trailingFence.length)).toBeNull();
  });

  it("skips front matter and fenced headings", () => {
    const source = "---\ntitle: 中文\n---\n# 第一章\n内容\n## 子章\n```md\n# 不是章节\n```\n# 第二章";
    const sections = getMarkdownSections(source);
    expect(sections.map((section) => section.title)).toEqual(["第一章", "子章", "第二章"]);
    expect(sections[0].to).toBe(source.indexOf("# 第二章"));
    expect(getMarkdownSections("+++\ntitle = '# 不是章节'\n+++\n# 正文").map((section) => section.title)).toEqual(["正文"]);
  });

  it("moves, duplicates, and deletes top-level sections with boundaries", () => {
    const source = "# 一\na\n## 子\nx\n# 二\nb";
    const moved = moveMarkdownSection(source, 0, "down");
    expect(moved?.text.indexOf("# 二")).toBeLessThan(moved?.text.indexOf("# 一") ?? 0);
    expect(moved?.text.slice(moved.selection.from).startsWith("# 一")).toBe(true);
    expect(moveMarkdownSection(source, 2, "down")).toBeNull();
    const duplicate = duplicateMarkdownSection(source, 1);
    expect(duplicate?.text.match(/^## 子/gm)?.length).toBe(2);
    expect(duplicate?.text.slice(duplicate.selection.from).startsWith("## 子")).toBe(true);
    const deleted = deleteMarkdownSection(source, 0);
    expect(deleted?.text.startsWith("# 二")).toBe(true);
  });

  it("does not move sections across different parents", () => {
    const source = "# A\n## A1\n### A1a\n## A2\n# B\n## B1";
    const moved = moveMarkdownSection(source, 1, "down");
    expect(moved?.text.indexOf("## A2")).toBeLessThan(moved?.text.indexOf("## A1") ?? 0);
    expect(moveMarkdownSection(source, 5, "up")).toBeNull();
  });

  it("keeps CRLF offsets and ignores whitespace-only gaps at section boundaries", () => {
    const source = "# 甲\r\n内容\r\n\r\n# 乙\r\n末尾";
    const sections = getMarkdownSections(source);
    expect(sections.map((section) => section.title)).toEqual(["甲", "乙"]);
    expect(source.slice(sections[0].from, sections[0].to)).toContain("内容");
    expect(moveMarkdownSection(source, 0, "up")).toBeNull();
    expect(moveMarkdownSection(source, 1, "down")).toBeNull();
  });

  it("indents list and quote lines, but leaves ordinary prose alone", () => {
    const source = "- 一\n> 二";
    const indented = applyMarkdownIndent(source, { from: 0, to: source.length }, "indent");
    expect(indented.text).toBe("  - 一\n  > 二");
    expect(applyMarkdownIndent(indented.text, { from: 0, to: indented.text.length }, "outdent").text).toBe(source);
    expect(applyMarkdownIndent("- abc", { from: 2, to: 2 }, "indent").selection).toEqual({ from: 4, to: 4 });
    expect(applyMarkdownIndent("  - abc", { from: 5, to: 5 }, "outdent").selection).toEqual({ from: 3, to: 3 });
    const prose = "普通正文\n第二行";
    expect(applyMarkdownIndent(prose, { from: 0, to: prose.length }, "indent").text).toBe(prose);
    expect(applyMarkdownIndent("1、中文", { from: 0, to: 4 }, "indent").text).toBe("  1、中文");
  });

  it("creates stable GitHub-style anchors while preserving Chinese", () => {
    const source = "# Hello, 世界!\n# Hello, 世界!\n# A title";
    expect(getMarkdownSectionAnchor(source, 0)).toBe("hello-世界");
    expect(getMarkdownSectionAnchor(source, 1)).toBe("hello-世界-1");
  });
});
