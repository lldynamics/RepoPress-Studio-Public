import { describe, expect, it } from "vitest";
import { createMarkdownDocumentExportPlan, safeSuggestedFileName } from "./markdownDocumentExport";

describe("createMarkdownDocumentExportPlan", () => {
  it("exports an unsaved buffer unchanged as UTF-8 Markdown", () => {
    const markdown = "# 未保存\n\n保留  空格\n";
    const plan = createMarkdownDocumentExportPlan({ markdown }, "markdown");
    expect(plan).toMatchObject({
      format: "markdown",
      text: markdown,
      encoding: "utf-8",
      mimeType: "text/markdown",
      extension: "md",
      suggestedFileName: "未命名文稿.md",
    });
  });

  it("uses front matter title ahead of the source filename and omits metadata from HTML", () => {
    const plan = createMarkdownDocumentExportPlan({
      markdown: "---\ntitle: \"中文标题\"\n---\n\n# 正文",
      fileName: "/drafts/other-name.md",
      title: "编辑器标题",
    }, "html");
    expect(plan.suggestedFileName).toBe("中文标题.html");
    expect(plan.text).toContain("<title>中文标题</title>");
    expect(plan.text).toContain("<h1>正文</h1>");
    expect(plan.text).not.toContain("title: ");
    expect(plan).toMatchObject({ encoding: "utf-8", mimeType: "text/html", extension: "html" });
  });

  it("uses the current file basename when front matter has no title", () => {
    const plan = createMarkdownDocumentExportPlan({ markdown: "内容", fileName: "notes/你好.world.md" }, "markdown");
    expect(plan.suggestedFileName).toBe("你好.md");
  });

  it("makes filenames safe across path syntax, extensions, trailing dots, and reserved names", () => {
    expect(safeSuggestedFileName("../../报告.exe", "md")).toBe("..-..-报告.md");
    expect(safeSuggestedFileName("CON.txt", "html")).toBe("CON-document.html");
    expect(safeSuggestedFileName("COM1.exe.md", "html")).toBe("COM1-document.html");
    expect(safeSuggestedFileName("aux. ", "md")).toBe("aux-document.md");
    expect(safeSuggestedFileName("bad\u0000:name. ", "md")).toBe("bad-name.md");
  });

  it("makes HTML self-contained and rejects executable markup, remote resources, and navigation", () => {
    const plan = createMarkdownDocumentExportPlan({
      markdown: [
        "<script>alert(1)</script>",
        "<iframe src=\"https://evil.example\"></iframe>",
        "<form action=\"https://evil.example\"></form>",
        "<img src=\"https://evil.example/a.png\" onerror=\"alert(2)\">",
        "[外链](https://evil.example)",
        "![远程图](https://evil.example/b.png)",
      ].join("\n\n"),
    }, "html");
    expect(plan.text).toContain("<!doctype html>");
    expect(plan.text).toContain('<meta charset="utf-8">');
    expect(plan.text).not.toMatch(/<(?:script|iframe|object|embed|form)\b/i);
    expect(plan.text).not.toMatch(/\s(?:on\w+|style|href|src|srcset)\s*=/i);
    expect(plan.text).toContain("图片资源已阻止");
  });
});
