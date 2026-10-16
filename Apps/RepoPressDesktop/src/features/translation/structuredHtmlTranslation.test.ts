import { describe, expect, it } from "vitest";
import type { StructuredTextTranslationResult } from "../../contracts/repository";
import {
  buildStructuredHtmlTranslationPlan,
  decodeStructuredTextTranslationResult,
  encodeStructuredTextTranslationResult,
  reconstructStructuredHtmlTranslation,
} from "./structuredHtmlTranslation";

function result(translations: Array<{ id: string; translatedText: string }>): StructuredTextTranslationResult {
  return {
    translations,
    detectedSourceLanguage: "en",
    provider: "ollama_local",
    model: "test",
    targetLanguage: "zh",
  };
}

describe("structured HTML RSS translation", () => {
  it("plans title and visible text nodes while preserving each node's whitespace", () => {
    const plan = buildStructuredHtmlTranslationPlan({
      title: " Source title ",
      html: "<p> Hello <a href='/read'>world</a> </p><pre>keep</pre><code>code</code><script>x()</script><svg>vector</svg><p>\nNext\n</p>",
    });

    expect(plan.segments).toEqual([
      { id: "title", text: " Source title " },
      { id: "body.0", text: " Hello " },
      { id: "body.1", text: "world" },
      { id: "body.2", text: "\nNext\n" },
    ]);
    expect(plan.wasTruncated).toBe(false);
  });

  it("reconstructs only through text nodes and preserves tags, attributes, and excluded content", () => {
    const plan = buildStructuredHtmlTranslationPlan({
      title: "Original",
      html: "<p class='lead'>Hello <a href='https://example.test/x' data-id='a'>world</a>.</p><pre>const x = 1;</pre><script>keep()</script>",
    });
    const output = reconstructStructuredHtmlTranslation(plan, result([
      { id: "title", translatedText: "标题" },
      { id: "body.0", translatedText: "你好 " },
      { id: "body.1", translatedText: "<script>not executable</script>" },
      { id: "body.2", translatedText: "。" },
    ]));

    expect(output.translatedTitle).toBe("标题");
    expect(output.translatedHtml).toContain("class=\"lead\"");
    expect(output.translatedHtml).toContain("href=\"https://example.test/x\"");
    expect(output.translatedHtml).toContain("<pre>const x = 1;</pre>");
    expect(output.translatedHtml).toContain("<script>keep()</script>");
    expect(output.translatedHtml).toContain("&lt;script&gt;not executable&lt;/script&gt;");
    expect(output.translatedPlainText).toContain("<script>not executable</script>");
    expect(output.translatedPlainText).not.toContain("keep()");
  });

  it("keeps inline text together and separates reader blocks in plain-text output", () => {
    const plan = buildStructuredHtmlTranslationPlan({
      title: " Original ",
      html: "<p>Hello <strong>world</strong>.</p><p>Next<br>line</p><pre>skip me</pre>",
    });
    const output = reconstructStructuredHtmlTranslation(plan, result([
      { id: "title", translatedText: " 标题 " },
      { id: "body.0", translatedText: "你好 " },
      { id: "body.1", translatedText: "世界" },
      { id: "body.2", translatedText: "。" },
      { id: "body.3", translatedText: "下一" },
      { id: "body.4", translatedText: "行" },
    ]));

    expect(output.translatedTitle).toBe("标题");
    expect(output.translatedPlainText).toBe("你好 世界。\n\n下一\n行");
  });

  it("fails closed for missing, duplicate, extra, and empty result ids", () => {
    const plan = buildStructuredHtmlTranslationPlan({ title: "T", html: "<p>One</p>" });
    expect(() => reconstructStructuredHtmlTranslation(plan, result([{ id: "title", translatedText: "译" }]))).toThrow();
    expect(() => reconstructStructuredHtmlTranslation(plan, result([
      { id: "title", translatedText: "译" }, { id: "body.0", translatedText: "一" }, { id: "body.0", translatedText: "二" },
    ]))).toThrow();
    expect(() => reconstructStructuredHtmlTranslation(plan, result([
      { id: "title", translatedText: "译" }, { id: "body.0", translatedText: "一" }, { id: "body.1", translatedText: "额外" },
    ]))).toThrow();
    expect(() => reconstructStructuredHtmlTranslation(plan, result([
      { id: "title", translatedText: "译" }, { id: "body.0", translatedText: "  " },
    ]))).toThrow();
  });

  it("does not split UTF-8 text and leaves overflowing body nodes unplanned", () => {
    const plan = buildStructuredHtmlTranslationPlan({
      title: "A",
      html: "<p>😀</p><p>tail</p>",
      maxTextBytes: 5,
    });
    expect(plan.segments).toEqual([{ id: "title", text: "A" }, { id: "body.0", text: "😀" }]);
    expect(plan.sourceTextBytes).toBe(5);
    expect(plan.wasTruncated).toBe(true);
    expect(reconstructStructuredHtmlTranslation(plan, result([
      { id: "title", translatedText: "甲" }, { id: "body.0", translatedText: "乙" },
    ])).translatedHtml).toContain("<p>tail</p>");

    const longTitle = buildStructuredHtmlTranslationPlan({ title: "😀".repeat(501), html: "" });
    expect(Array.from(longTitle.segments[0].text)).toHaveLength(500);
    expect(new TextEncoder().encode(longTitle.segments[0].text).byteLength).toBe(2_000);
    expect(longTitle.wasTruncated).toBe(true);
  });

  it("caps the request at the backend segment limit and leaves later nodes unchanged", () => {
    const html = Array.from({ length: 300 }, (_, index) => `<p>node ${index}</p>`).join("");
    const plan = buildStructuredHtmlTranslationPlan({ title: "Title", html });

    expect(plan.segments).toHaveLength(256);
    expect(plan.segments[255]).toEqual({ id: "body.254", text: "node 254" });
    expect(plan.wasTruncated).toBe(true);
    const output = reconstructStructuredHtmlTranslation(plan, result(
      plan.segments.map(({ id }) => ({ id, translatedText: `translated ${id}` })),
    ));
    expect(output.translatedHtml).toContain("<p>translated body.254</p><p>node 255</p>");
  });

  it("encodes only translations in a versioned envelope and ignores legacy plain text", () => {
    const encoded = encodeStructuredTextTranslationResult(result([
      { id: "title", translatedText: "标题" }, { id: "body.0", translatedText: "正文" },
    ]));
    expect(encoded).toMatch(/^repopress-structured-translation:v1:/);
    expect(encoded).not.toContain("Original source HTML");
    expect(decodeStructuredTextTranslationResult(encoded)).toEqual({
      translations: [{ id: "title", translatedText: "标题" }, { id: "body.0", translatedText: "正文" }],
    });
    expect(decodeStructuredTextTranslationResult("legacy plain translation")).toBeNull();
    expect(decodeStructuredTextTranslationResult("repopress-structured-translation:v1:{bad")).toBeNull();
  });
});
