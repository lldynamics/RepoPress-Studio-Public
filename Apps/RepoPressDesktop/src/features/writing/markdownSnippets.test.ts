import { describe, expect, it } from "vitest";
import { availableMarkdownSnippets, BUILT_IN_MARKDOWN_SNIPPETS, expandMarkdownSnippet, insertMarkdownSnippet, normalizeSnippetShortcut, removeCustomMarkdownSnippet, saveCustomMarkdownSnippet } from "./markdownSnippets";
const s = (n: number) => ({ id: `x${n}`, label: `X${n}`, shortcut: `x${n}`, kind: "snippet" as const, template: "Hi {{title}}", selectionToken: "{{title}}" });
describe("markdown snippets", () => { it("normalizes Unicode shortcuts and rejects unsafe values", () => { expect(normalizeSnippetShortcut(" /Hello_1 ")).toBe("hello_1"); expect(normalizeSnippetShortcut("/提示-1")).toBe("提示-1"); expect(normalizeSnippetShortcut("bad shortcut")).toBe(""); expect(normalizeSnippetShortcut("a/b")).toBe(""); });
  it("expands date/title and inserts selected token", () => { const item = { ...s(1), template: "## {{title}} {{slug}} {{date}}" }; expect(expandMarkdownSnippet(item, { title: "T", slug: "s", date: "2026-09-03" })).toBe("## T s 2026-09-03"); const out = insertMarkdownSnippet("old", { from: 3, to: 0 }, s(2), { title: "T" }); expect(out.text).toBe("Hi old"); expect(out.selection.to - out.selection.from).toBe(3); });
  it("keeps macOS-compatible built-in writing structures", () => { expect(BUILT_IN_MARKDOWN_SNIPPETS.find((item) => item.id === "tutorial")?.template).toContain("## 验证结果"); expect(BUILT_IN_MARKDOWN_SNIPPETS.find((item) => item.id === "callout")?.template).toContain("::: tip 提示"); expect(BUILT_IN_MARKDOWN_SNIPPETS.find((item) => item.id === "mermaid")?.template).toContain("flowchart TD"); });
  it("provides every macOS SSG snippet with its compatible shortcut and template", () => {
    const expected = [
      ["callout", "callout", "::: tip 提示\n在这里输入提示内容。\n:::", "在这里输入提示内容。"],
      ["ssg-lead", "lead", "{{< lead >}}\n在这里输入文章导语。\n{{< /lead >}}", "在这里输入文章导语。"],
      ["ssg-youtube", "youtube", "{{< youtube VIDEO_ID >}}", "VIDEO_ID"],
      ["ssg-bilibili", "bilibili", "{{< bilibili BV_ID >}}", "BV_ID"],
      ["ssg-github-card", "github", "{{< github-card owner/repo >}}", "owner/repo"],
      ["ssg-figure", "figure", "{{< figure src=\"/images/example.jpg\" title=\"图片说明\" >}}", "/images/example.jpg"],
    ] as const;
    for (const [id, shortcut, template, token] of expected) {
      const snippet = BUILT_IN_MARKDOWN_SNIPPETS.find((item) => item.id === id);
      expect(snippet).toMatchObject({ id, shortcut, template, selectionToken: token, kind: "snippet" });
      const out = insertMarkdownSnippet("已有内容", { from: 0, to: 4 }, snippet!, { title: "文章" });
      expect(out.text).toContain("已有内容");
      expect(out.selection).toEqual({ from: out.text.indexOf("已有内容"), to: out.text.indexOf("已有内容") + 4 });
    }
    expect(new Set(expected.map(([, shortcut]) => shortcut)).size).toBe(expected.length);
  });
  it("scopes custom snippets, caps at 100 and protects builtins", () => { for (let i = 0; i < 105; i++) saveCustomMarkdownSnippet("a", s(i)); expect(availableMarkdownSnippets("a").length).toBe(BUILT_IN_MARKDOWN_SNIPPETS.length + 100); expect(saveCustomMarkdownSnippet("b", { ...s(1), id: "tutorial", shortcut: "tutorial" })).toHaveLength(0); expect(removeCustomMarkdownSnippet("a", "x104")).toHaveLength(99); }); });
