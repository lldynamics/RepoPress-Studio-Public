import { afterEach, describe, expect, it, vi } from "vitest";
import * as draftHistory from "./draftHistory";
import { compareDraftSections } from "./draftComparison";

afterEach(() => vi.restoreAllMocks());

describe("draft comparison sections", () => {
  it.each(["", "正文\n\n", "# Header\r\n---\r\nbody", "\n---\nkey: value\n---\nbody", "--- extra\nbody", "+++ extra\nbody"])(
    "keeps plain documents and later delimiters in the whole body: %j", (text) => {
      const result = compareDraftSections(text, "source");
      expect(result).toEqual({ full: draftHistory.compareDraftVersion(text, "source"), frontMatter: null, body: result.full, fallback: null });
      expect(result.body).toBe(result.full);
    },
  );

  it.each([
    ["---\ntitle: new\n---\n正文", "---\ntitle: new\n---\n", "正文"],
    ["+++\ntitle = 'new'\n+++\n正文", "+++\ntitle = 'new'\n+++\n", "正文"],
  ])("compares creation and removal in target-against-source direction: %j", (text, preamble, body) => {
    const created = compareDraftSections(text, body);
    expect(created.frontMatter).toEqual(draftHistory.compareDraftVersion(preamble, ""));
    expect(created.frontMatter?.addedCount).toBeGreaterThan(0);
    expect(created.frontMatter?.removedCount).toBe(0);
    expect(created.body).toEqual(draftHistory.compareDraftVersion(body, body));
    const removed = compareDraftSections(body, text);
    expect(removed.frontMatter).toEqual(draftHistory.compareDraftVersion("", preamble));
    expect(removed.frontMatter?.addedCount).toBe(0);
    expect(removed.frontMatter?.removedCount).toBeGreaterThan(0);
    expect(removed.body).toEqual(created.body);
  });

  it("treats YAML and TOML format changes as raw text changes", () => {
    const target = "+++\ntitle = 'same'\n+++\nbody";
    const source = "---\ntitle: same\n---\nbody";
    const result = compareDraftSections(target, source);
    expect(result.full).toEqual(draftHistory.compareDraftVersion(target, source));
    expect(result.frontMatter).toEqual(draftHistory.compareDraftVersion("+++\ntitle = 'same'\n+++\n", "---\ntitle: same\n---\n"));
    expect(result.body?.addedCount).toBe(0);
    expect(result.body?.removedCount).toBe(0);
  });

  it("retains scalar style, unknown fields, comments, multiline values and unsupported syntax", () => {
    const sourcePreamble = "---\n# keep me\ntitle: 'same'\nunknown: !custom {raw: true}\nsummary: |\n  line one\n  <b>{{ literal }}</b>\n---\n";
    const targetPreamble = '---\n# keep me\ntitle: "same"\nunknown: !other [raw, true]\nsummary: >\n  line one\n  <b>{{ literal }}</b>\n---\n';
    const body = "\n{{ unknown }}\n<script>literal</script>\n\n";
    const comparison = vi.spyOn(draftHistory, "compareDraftVersion");
    const result = compareDraftSections(targetPreamble + body, sourcePreamble + body);
    expect(comparison.mock.calls).toEqual([
      [targetPreamble + body, sourcePreamble + body],
      [targetPreamble, sourcePreamble],
      [body, body],
    ]);
    expect(result.frontMatter?.addedCount).toBe(3);
    expect(result.frontMatter?.removedCount).toBe(3);
    expect(result.body?.lines.map((line) => line.text)).toEqual(["", "{{ unknown }}", "<script>literal</script>", "", ""]);
  });

  it("retains TOML comments, unknown arrays, tables and multiline strings verbatim", () => {
    const preamble = '+++\n# comment\nunknown = [1, { x = "{{raw}}" }]\n[custom.table]\ntext = """\n  multiline\n  <html>\n"""\n+++\n';
    const comparison = vi.spyOn(draftHistory, "compareDraftVersion");
    compareDraftSections(preamble + "body", "body");
    expect(comparison.mock.calls[1]).toEqual([preamble, ""]);
    expect(comparison.mock.calls[2]).toEqual(["body", "body"]);
  });

  it.each([
    ["\uFEFF \t--- \t\r\nkey: value\r... \t\n", "\r\n\n正文\r"],
    ["\uFEFF+++\rkey = 1\n+++\r\n", "\r\n正文\n\n"],
    ["---\n---", ""],
    ["---\r\n---\r\n", ""],
    ["+++\r+++\r", ""],
    ["---\n---\n", "\n\n"],
    ["---\n...\r", "body"],
  ])("partitions BOM, mixed endings and empty or blank bodies losslessly: %j", (preamble, body) => {
    const comparison = vi.spyOn(draftHistory, "compareDraftVersion");
    const result = compareDraftSections(preamble + body, "source");
    expect(comparison.mock.calls).toEqual([[preamble + body, "source"], [preamble, ""], [body, "source"]]);
    expect(result.fallback).toBeNull();
    expect(result.frontMatter).not.toBeNull();
  });

  it.each(["---", "+++\n", "---\nkey: value", "---\n+++\nbody", "+++\n...\nbody", "---\n--- extra\nbody", "+++\n+++ extra\nbody"])(
    "falls back to the original whole diff when either preamble is unclosed: %j", (malformed) => {
      const good = "---\ntitle: ok\n---\nbody";
      for (const [target, source] of [[malformed, good], [good, malformed], [malformed, malformed]]) {
        const expected = draftHistory.compareDraftVersion(target, source);
        const comparison = vi.spyOn(draftHistory, "compareDraftVersion");
        const result = compareDraftSections(target, source);
        expect(result).toEqual({ full: expected, frontMatter: null, body: null, fallback: "unclosedFrontMatter" });
        expect(comparison.mock.calls).toEqual([[target, source]]);
        comparison.mockRestore();
      }
    },
  );

  it("uses only the first valid closing delimiter and keeps later delimiters in the body", () => {
    const comparison = vi.spyOn(draftHistory, "compareDraftVersion");
    compareDraftSections("---\n---\nbody\n---\n+++\n", "---\n---\nold");
    expect(comparison.mock.calls[1]).toEqual(["---\n---\n", "---\n---\n"]);
    expect(comparison.mock.calls[2]).toEqual(["body\n---\n+++\n", "old"]);
  });

  it("keeps target additions, source removals and section-local line numbers", () => {
    const result = compareDraftSections("---\ntitle: new\n---\nnew body", "---\ntitle: old\n---\nold body");
    expect(result.frontMatter?.lines).toContainEqual({ kind: "added", text: "title: new", currentLine: 2, historicalLine: null });
    expect(result.frontMatter?.lines).toContainEqual({ kind: "removed", text: "title: old", currentLine: null, historicalLine: 2 });
    expect(result.body?.lines).toEqual([
      { kind: "added", text: "new body", currentLine: 1, historicalLine: null },
      { kind: "removed", text: "old body", currentLine: null, historicalLine: 1 },
    ]);
  });

  it.each([
    "---\n" + "field: value\n".repeat(200) + "---\n" + "body\n".repeat(200),
    "---\n" + "x".repeat(70 * 1024) + "\n---\n" + "y".repeat(70 * 1024),
    "---\n---\n" + "中".repeat(44 * 1024),
  ])("applies whole-document caps before any section comparisons", (huge) => {
    const expected = draftHistory.compareDraftVersion(huge, "small");
    const comparison = vi.spyOn(draftHistory, "compareDraftVersion");
    expect(compareDraftSections(huge, "small")).toEqual({ full: expected, frontMatter: null, body: null, fallback: "comparisonLimit" });
    expect(expected.truncated).toBe(true);
    expect(comparison.mock.calls).toEqual([[huge, "small"]]);
  });

  it("checks both sides and gives comparison limits priority over an unclosed preamble", () => {
    const huge = "---\n" + "中".repeat(44 * 1024);
    const comparison = vi.spyOn(draftHistory, "compareDraftVersion");
    const result = compareDraftSections("---", huge);
    expect(result).toMatchObject({ frontMatter: null, body: null, fallback: "comparisonLimit", full: { truncated: true, lines: [] } });
    expect(comparison.mock.calls).toEqual([["---", huge]]);
  });

  it("allows documents at the existing 400-line and 128-KiB boundaries", () => {
    const exactLines = "---\n---\n" + Array.from({ length: 398 }, (_, index) => `body ${index}`).join("\n");
    expect(compareDraftSections(exactLines, "").full.truncated).toBe(false);
    const exactBytes = "---\n---\n" + "x".repeat(128 * 1024 - 8);
    expect(compareDraftSections(exactBytes, "").full.truncated).toBe(false);
    expect(compareDraftSections(exactBytes + "x", "").fallback).toBe("comparisonLimit");
  });
});
