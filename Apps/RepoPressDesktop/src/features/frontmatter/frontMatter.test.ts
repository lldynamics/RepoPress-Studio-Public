import { describe, expect, it } from "vitest";
import { addDefaultFrontMatter, adjustSelectionAfterFrontMatterChange, parseFrontMatter, updateFrontMatterField } from "./frontMatter";

describe("front matter editing", () => {
  it("parses YAML fields and preserves the body offset", () => {
    const source = '---\ntitle: "Hello"\npermalink: /guide/hello/\ntags:\n  - one\n  - two\ndraft: false\n---\n\n# Body';
    const parsed = parseFrontMatter(source);
    expect(parsed?.values).toMatchObject({ title: "Hello", permalink: "/guide/hello/", tags: ["one", "two"], draft: false });
    expect(source.slice(parsed?.bodyOffset)).toBe("# Body");
  });

  it("updates known fields without dropping unknown metadata or body text", () => {
    const source = '---\ntitle: old\ncustom: keep-me\ntags: [one]\n---\n\nBody';
    const updated = updateFrontMatterField(updateFrontMatterField(source, "title", "New"), "tags", ["A", "a", "B"]);
    expect(updated).toContain('title: "New"');
    expect(updated).toContain("custom: keep-me");
    expect(updated).toContain('tags: ["A", "B"]');
    expect(updated.endsWith("Body")).toBe(true);
  });

  it("refuses structured edits for unsupported or malformed fields", () => {
    const malformed = "---\ntags: {one: two}\n---\nBody";
    expect(parseFrontMatter(malformed)?.issue).toContain("tags");
    expect(updateFrontMatterField(malformed, "title", "Nope")).toBe(malformed);
  });

  it("adds a safe default and keeps a body selection stable", () => {
    const source = "# Existing";
    const updated = addDefaultFrontMatter(source, "2026-09-03");
    const selection = adjustSelectionAfterFrontMatterChange(source, updated, { from: 2, to: 10 });
    expect(updated).toContain('date: "2026-09-03"');
    expect(updated.slice(selection.from, selection.to)).toBe("Existing");
  });

  it("supports TOML without changing its delimiter style", () => {
    const source = '+++\ntitle = "Old"\ntags = ["one"]\n+++\n\nBody';
    const updated = updateFrontMatterField(source, "title", "New");
    expect(updated.startsWith('+++\ntitle = "New"')).toBe(true);
    expect(parseFrontMatter(updated)?.style).toBe("toml");
  });

  it("accepts the YAML document-end delimiter and CRLF offsets", () => {
    const source = "---\r\ntitle: Guide\r\nslug: guide\r\n...\r\n\r\n# 正文";
    const parsed = parseFrontMatter(source);
    expect(parsed?.issue).toBeNull();
    expect(parsed?.values).toMatchObject({ title: "Guide", slug: "guide" });
    expect(source.slice(parsed?.bodyOffset)).toBe("# 正文");
  });
});
