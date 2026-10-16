import { describe, expect, it } from "vitest";
import { getMarkdownSSGComponentOccurrences } from "./markdownSSGComponents";

describe("Markdown SSG components", () => {
  it("recognizes directive, paired Hugo, and inline SSG components in source order", () => {
    const source = "::: tip 注意\n先确认提示框。\n:::\n\n{{< lead >}}\n文章导语。\n{{< /lead >}}\n{{< admonition 警告 >}}\n请确认配置。\n{{< /admonition >}}\n{{< youtube dQw4w9WgXcQ >}}\n{{< bilibili BV1xx411c7mD >}}\n{{< github-card openai/codex >}}\n{{< figure src=\"/image.jpg\" >}}\n{{< product-card item=\"one\" >}}";
    const items = getMarkdownSSGComponentOccurrences(source);
    expect(items.map((item) => item.kind)).toEqual(["callout", "lead", "callout", "youtube", "bilibili", "githubCard", "figure", "custom"]);
    expect(items[0]).toMatchObject({ title: "注意", previewText: "先确认提示框。", lineNumber: 1 });
    expect(items[1].previewText).toBe("文章导语。");
    expect(items[3].previewText).toBe("dQw4w9WgXcQ");
    expect(items[5].previewText).toBe("openai/codex");
    expect(source.slice(items[6].sourceRange.from, items[6].sourceRange.to)).toBe(items[6].source);
  });

  it("does not inspect front matter, fenced code, or inline text", () => {
    const source = "---\nexample: '{{< youtube ignored >}}'\n---\n`{{< figure ignored >}}`\n```md\n::: warning\nignored\n:::\n{{< youtube ignored >}}\n```\n{{< youtube real >}}";
    const items = getMarkdownSSGComponentOccurrences(source);
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ kind: "youtube", previewText: "real", lineNumber: 11 });
  });

  it("keeps unclosed containers through EOF and uses CRLF UTF-16 ranges", () => {
    const source = "😀\r\n{{< lead >}}\r\n第一行\r\n第二行";
    const item = getMarkdownSSGComponentOccurrences(source)[0];
    expect(item).toMatchObject({ kind: "lead", lineNumber: 2, previewText: "第一行 第二行" });
    expect(item.sourceRange.from).toBe(source.indexOf("{{< lead >}}"));
    expect(item.sourceRange.to).toBe(source.length);
    expect(item.source).toBe(source.slice(item.sourceRange.from));
  });

  it("compacts previews to at most 96 Unicode characters", () => {
    const source = `::: note\n${"😀".repeat(120)}\n:::`;
    const item = getMarkdownSSGComponentOccurrences(source)[0];
    expect(Array.from(item.previewText)).toHaveLength(96);
  });

  it("supports more than twelve components without truncating the source model", () => {
    const source = Array.from({ length: 13 }, (_, index) => `{{< youtube ${index} >}}`).join("\n");
    const items = getMarkdownSSGComponentOccurrences(source);
    expect(items).toHaveLength(13);
    expect(items[12]).toMatchObject({ previewText: "12", lineNumber: 13 });
  });
});
