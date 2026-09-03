import { describe, expect, it } from "vitest";
import { renderMarkdownPreview } from "./renderMarkdownPreview";
describe("renderMarkdownPreview", () => {
  it("removes executable markup, inline handlers, and remote resources", () => { const html = renderMarkdownPreview("<script>alert(1)</script><img src=\"https://evil.example/a.png\" onerror=\"alert(2)\">[危险](javascript:alert(3))"); expect(html).not.toMatch(/script|onerror|javascript:|src=/i); });
  it("replaces Markdown image resources instead of loading them", () => { expect(renderMarkdownPreview("![远程图片](https://evil.example/a.png)")).toContain("图片资源已阻止"); });
  it("marks links as external without preserving navigation", () => { const html = renderMarkdownPreview("[官网](https://example.com)"); expect(html).toContain('data-external-link="true"'); expect(html).not.toContain("href="); });
  it("omits Zola front matter from the reading preview", () => {
    const html = renderMarkdownPreview('+++\ntitle = "中文测试"\n+++\n\n# 正文');
    expect(html).toContain("<h1>正文</h1>");
    expect(html).not.toContain("title =");
  });
});
