import { describe, expect, it } from "vitest";
import { MARKDOWN_SMART_PASTE_MAX_SIZE, convertRichTextPasteHtml, planMarkdownSmartPaste, sanitizeMarkdownPasteUrl } from "./markdownSmartPaste";

describe("markdown smart paste", () => {
  it("wraps a selected UTF-16 label in a clean web link", () => {
    const source = "😀 Read a ] guide";
    const from = source.indexOf("a ] guide");
    const plan = planMarkdownSmartPaste(source, { from, to: source.length }, { plainText: " https://example.com/a_(b)?utm_source=x&fbclid=y " });
    expect(plan).toMatchObject({ text: "😀 Read [a \\] guide](<https://example.com/a_(b)>)", kind: "link", removedTrackingParameterCount: 2, status: "applied" });
    expect(plan?.selection).toEqual({ from: plan!.text.length, to: plan!.text.length });
  });

  it("prioritizes a selected-label URL over accompanying HTML clipboard content", () => {
    const source = "阅读指南";
    const from = source.indexOf("指南");
    const plan = planMarkdownSmartPaste(source, { from, to: source.length }, {
      plainText: "https://example.com/docs?utm_source=x",
      html: "<a href='https://example.com/docs'>别的标签</a>",
    });
    expect(plan).toMatchObject({ text: "阅读[指南](https://example.com/docs)", kind: "link", removedTrackingParameterCount: 1 });
  });

  it("keeps ordinary text for the platform paste path and clamps stale ranges", () => {
    expect(planMarkdownSmartPaste("hello", { from: 99, to: -3 }, { plainText: "ordinary text" })).toBeNull();
    expect(planMarkdownSmartPaste("hello", { from: 9, to: 3 }, { plainText: "https://example.com" })?.text).toBe("hel[lo](https://example.com/)");
    expect(planMarkdownSmartPaste("abc", { from: 3, to: -5 }, { plainText: "https://example.com" })?.text).toBe("[abc](https://example.com/)");
  });

  it("matches the macOS rich-text heading, list, link, and tracking behavior", () => {
    const conversion = convertRichTextPasteHtml("<main><h2>发布说明</h2><p>请阅读 <strong>完整</strong> <a href='https://example.com/guide?id=42&utm_source=mail&fbclid=secret'>指南</a>。</p><ol start='3'><li>检查草稿</li><li>发布站点<ul><li>确认状态</li></ul></li></ol><script>steal()</script></main>");
    expect(conversion).toEqual({ markdown: "## 发布说明\n\n请阅读 **完整** [指南](https://example.com/guide?id=42)。\n\n3. 检查草稿\n4. 发布站点\n  - 确认状态", removedTrackingParameterCount: 2 });
    expect(convertRichTextPasteHtml("<h1>单独标题</h1>")?.markdown).toBe("# 单独标题");
  });

  it("converts tables, safe code fences, and sanitized images", () => {
    const conversion = convertRichTextPasteHtml("<table><tr><th align='left'>名称</th><th style='text-align:right'>数量</th></tr><tr><td>苹果 | 梨</td><td>2</td></tr></table><pre><code class='language-swift'>let value = ```raw```</code></pre><p><img src='https://example.com/image.png?utm_campaign=spring' alt='结构图'></p>");
    expect(conversion?.markdown).toContain("| 苹果 \\| 梨 | 2 |");
    expect(conversion?.markdown).toContain("````swift\nlet value = ```raw```\n````");
    expect(conversion?.markdown).toContain("![结构图](https://example.com/image.png)");
    expect(conversion?.removedTrackingParameterCount).toBe(1);
  });

  it("resolves relative URLs but strips credentials, controls, scripts, and unsafe image destinations", () => {
    expect(convertRichTextPasteHtml("<p><a href='guide?a=1&utm_medium=x#part'>相对</a> <a href='javascript:alert(1)'>危险</a><img src='file:///secret' alt='仅说明'></p>", "https://example.com/docs/")?.markdown).toBe("[相对](https://example.com/docs/guide?a=1#part) 危险仅说明");
    expect(sanitizeMarkdownPasteUrl("https://u:p@example.com/a")).toBeNull();
    expect(sanitizeMarkdownPasteUrl("https://example.com/a\u0000x")).toBeNull();
    expect(convertRichTextPasteHtml("<script>steal()</script><p>plain</p>")?.markdown).toBe("plain");
  });

  it("fails closed for oversize payloads and output without rich semantics", () => {
    const oversized = "x".repeat(MARKDOWN_SMART_PASTE_MAX_SIZE + 1);
    expect(convertRichTextPasteHtml(oversized)).toBeNull();
    expect(planMarkdownSmartPaste("x", { from: 0, to: 1 }, { plainText: oversized })).toBeNull();
    expect(convertRichTextPasteHtml("<span>only text</span>")).toBeNull();
  });
});
