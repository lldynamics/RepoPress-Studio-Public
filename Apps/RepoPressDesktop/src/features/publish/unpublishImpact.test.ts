import { describe, expect, it } from "vitest";
import type { ContentHealthSourceDocument, ContentHealthSourceSnapshot } from "../../contracts/repository";
import { analyzeUnpublishImpact } from "./unpublishImpact";
import { sameUnpublishImpactSources } from "./unpublishImpactSnapshot";

const mib = 1024 * 1024;

function document(relativePath: string, text: string, sha256 = `sha:${relativePath}:${text.length}`): ContentHealthSourceDocument {
  return { relativePath, displayName: relativePath.split("/").pop() ?? relativePath, text, byteSize: new TextEncoder().encode(text).length, sha256 };
}

function snapshot(documents: ContentHealthSourceDocument[], overrides: Partial<ContentHealthSourceSnapshot> = {}): ContentHealthSourceSnapshot {
  return {
    documents,
    totalFiles: documents.length,
    scannedFiles: documents.length,
    scannedBytes: documents.reduce((total, item) => total + item.byteSize, 0),
    omittedFiles: 0,
    truncated: false,
    omissions: [],
    warnings: [],
    ...overrides,
  };
}

function review(documents: ContentHealthSourceDocument[], targetPath = "target.md", targetText?: string) {
  const target = documents.find((item) => item.relativePath === targetPath);
  return analyzeUnpublishImpact({
    sources: snapshot(documents),
    target: { relativePath: targetPath, text: targetText ?? target?.text ?? "# Unsaved target" },
  });
}

describe("analyzeUnpublishImpact", () => {
  it("confirms literal relative source paths and retains absolute offsets after Front Matter", () => {
    const source = [
      "---",
      'title: "Source"',
      "---",
      "> [quoted](../target.md)",
      "- [listed](../target.md)",
      "[inline](../target.md)",
      "![image](../target.md)",
      "`[code](../target.md)`",
      "```md",
      "[fenced](../target.md)",
      "```",
      "<!-- [comment](../target.md) -->",
    ].join("\n");
    const report = review([document("target.md", "# Target"), document("notes/source.md", source)]);

    expect(report.targetAvailable).toBe(true);
    expect(report.partial).toBe(false);
    expect(report.findings.map(({ status, line, target, range }) => ({ status, line, target, text: source.slice(range.from, range.to) }))).toEqual([
      { status: "confirmed", line: 4, target: "../target.md", text: "[quoted](../target.md)" },
      { status: "confirmed", line: 5, target: "../target.md", text: "[listed](../target.md)" },
      { status: "confirmed", line: 6, target: "../target.md", text: "[inline](../target.md)" },
    ]);
  });

  it("resolves reference definitions once, including duplicate definitions, while excluding images", () => {
    const source = [
      "[first][published]",
      "[second][published]",
      "![image][published]",
      "",
      "[published]: ../target.md",
      "[published]: /target.md",
    ].join("\n");
    const report = review([document("target.md", "# Target"), document("posts/source.md", source)]);

    expect(report.findings).toHaveLength(2);
    expect(report.findings.map((item) => [item.status, item.target, item.line])).toEqual([
      ["confirmed", "../target.md", 1],
      ["confirmed", "../target.md", 2],
    ]);
  });

  it("keeps wiki titles and site routes possible rather than claiming rendered-site certainty", () => {
    const target = [
      "---",
      'title: "Published Article"',
      'slug: "published-article"',
      'permalink: "/articles/published/"',
      "---",
      "# Target",
    ].join("\n");
    const source = [
      "[[Published Article]]",
      "[[published-article|shown title]]",
      "[permalink](/articles/published/)",
      "[source-root](/target.md)",
    ].join("\n");
    const report = review([document("target.md", target), document("posts/source.md", source)]);

    expect(report.findings.map((item) => [item.status, item.target])).toEqual([
      ["possible", "Published Article"],
      ["possible", "published-article"],
      ["possible", "/articles/published/"],
      ["possible", "/target.md"],
    ]);
    expect(report.findings.every((item) => item.status !== "confirmed")).toBe(true);
  });

  it("accepts encoded in-root source paths but leaves escaping and unsupported destinations unresolved", () => {
    const source = [
      "[encoded name](../%74arget.md)",
      "[encoded traversal](%2e%2e/%74arget.md)",
      "[outside](../../target.md)",
      "[encoded separator](target%2Fmd)",
      "[double encoding](target%252Emd)",
      "[template](target{{value}}.md)",
      "[mail](mailto:target.md)",
      "[protocol-relative](//example.test/target.md)",
    ].join("\n");
    const report = review([document("target.md", "# Target"), document("posts/source.md", source)]);

    expect(report.findings.map((item) => [item.status, item.target])).toEqual([
      ["confirmed", "../%74arget.md"],
      ["confirmed", "%2e%2e/%74arget.md"],
      ["unresolved", "../../target.md"],
      ["unresolved", "target%2Fmd"],
      ["unresolved", "target%252Emd"],
      ["unresolved", "target{{value}}.md"],
    ]);
    expect(report.externalLinks).toBe(2);
    expect(report.partial).toBe(true);
  });

  it("does not confirm links when the disk target is absent, oversized, or duplicated", () => {
    const source = document("posts/source.md", "[target](../target.md)");
    const absent = review([source]);
    const oversized = review([document("target.md", "x".repeat(4 * mib + 1)), source]);
    const duplicate = review([document("target.md", "# First"), document("target.md", "# Second"), source]);

    for (const report of [absent, oversized, duplicate]) {
      expect(report.targetAvailable).toBe(false);
      expect(report.partial).toBe(true);
      expect(report.findings.some((item) => item.status === "confirmed")).toBe(false);
    }
    expect(absent.findings).toMatchObject([{ status: "unresolved", target: "../target.md" }]);
    expect(oversized.omittedDocuments).toBeGreaterThan(0);
    expect(duplicate.omittedDocuments).toBe(2);
  });

  it("keeps saved and edited target metadata as candidates without including self-links", () => {
    const saved = '---\ntitle: Old\npermalink: /old/\n---\n[self](target.md)';
    const edited = '---\ntitle: New\npermalink: /new/\n---\n[self](target.md)';
    const source = '[[Old]] [[New]]\n[old](/old/) [new](/new/)';
    const result = review([document("target.md", saved), document("source.md", source)], "target.md", edited);
    expect(result.targetEdited).toBe(true);
    expect(result.findings.map((item) => item.status)).toEqual(["possible", "possible", "possible", "possible"]);
    expect(result.findings.every((item) => item.documentPath === "source.md")).toBe(true);
    const oversizedOverlay = review([document("target.md", saved), document("source.md", "[t](target.md)")], "target.md", "x".repeat(4 * mib + 1));
    expect(oversizedOverlay).toMatchObject({ targetAvailable: false, omittedDocuments: 1, partial: true });
    expect(oversizedOverlay.findings[0].status).toBe("unresolved");
  });

  it("counts unavailable bodies and leaves unsupported HTML and entities as incomplete evidence", () => {
    const result = review([
      document("target.md", "# Target"),
      document("unclosed.md", "---\ntitle: open\n[target](target.md)"),
      document("source.mdx", '<a href="target.md">target</a>\n\n[x](target&#46;md)'),
    ]);
    expect(result).toMatchObject({ partial: true, omittedDocuments: 1, scannedDocuments: 2 });
    expect(result.findings).toMatchObject([{ status: "unresolved", target: "target&#46;md" }]);
    expect(result.warnings.join(" ")).toContain("HTML/MDX");
    expect(result.warnings.join(" ")).toContain("Front Matter 未闭合");
  });

  it("handles shortcut and collapsed references, ignores unused definitions and fenced containers", () => {
    const source = '[short]\n[collapsed][]\n\n[short]: target.md\n[collapsed]: target.md\n[unused]: target.md\n\n> ```\n> [hidden](target.md)\n> ```\n\n    [indented](target.md)\n\n[other](elsewhere.md)';
    const result = review([document("target.md", "# Target"), document("source.md", source)]);
    expect(result.findings).toHaveLength(2);
    expect(result.findings.map((item) => source.slice(item.range.from, item.range.to))).toEqual(["[short]", "[collapsed][]"]);
  });

  it("matches percent-encoded Unicode without case folding source paths", () => {
    const source = '[cn](%E4%B8%AD%20%E6%96%87.md#section) [other](%E4%B8%AD%20%E6%96%87.MD)';
    const result = review([document("中 文.md", "# 中文"), document("source.md", source)], "中 文.md");
    expect(result.findings).toHaveLength(1);
    expect(result.findings[0]).toMatchObject({ status: "confirmed", target: "%E4%B8%AD%20%E6%96%87.md#section" });
  });

  it("reserves the target and reports document, byte, finding, and reference caps as partial", () => {
    const target = document("target.md", "# Target");
    const tooManyDocuments = review([target, ...Array.from({ length: 1_000 }, (_, index) => document(`notes/${index}.md`, ""))]);
    expect(tooManyDocuments.targetAvailable).toBe(true);
    expect(tooManyDocuments.scannedDocuments).toBe(1_000);
    expect(tooManyDocuments.omittedDocuments).toBeGreaterThan(0);
    expect(tooManyDocuments.partial).toBe(true);

    const fourMiB = "x".repeat(4 * mib);
    const byteCapped = review([target, ...Array.from({ length: 8 }, (_, index) => document(`large/${index}.md`, fourMiB))]);
    expect(byteCapped.targetAvailable).toBe(true);
    expect(byteCapped.scannedDocuments).toBe(8);
    expect(byteCapped.omittedDocuments).toBeGreaterThan(0);
    expect(byteCapped.partial).toBe(true);

    const findingsCapped = review([target, document("posts/many.md", "[target](../target.md)\n".repeat(2_001))]);
    expect(findingsCapped.findings).toHaveLength(2_000);
    expect(findingsCapped.truncated).toBe(true);
    expect(findingsCapped.partial).toBe(true);

    const referencesCapped = review([target, document("posts/references.md", "[anchor](#skip)\n".repeat(20_001))]);
    expect(referencesCapped.findings).toHaveLength(0);
    expect(referencesCapped.truncated).toBe(true);
    expect(referencesCapped.partial).toBe(true);
  }, 30_000);
});

describe("sameUnpublishImpactSources", () => {
  it("accepts a reordered identical source set and rejects all evidence drift", () => {
    const first = snapshot([
      document("a.md", "# A", "sha-a"),
      document("b.md", "# B", "sha-b"),
    ], { omissions: [{ relativePath: null, code: "none", message: "none" }] });
    const reordered = snapshot([...first.documents].reverse(), { omissions: [...first.omissions] });

    expect(sameUnpublishImpactSources(first, reordered)).toBe(true);
    expect(sameUnpublishImpactSources(first, { ...first, documents: [{ ...first.documents[0], text: "# Changed" }, first.documents[1]] })).toBe(false);
    expect(sameUnpublishImpactSources(first, { ...first, documents: [{ ...first.documents[0], sha256: "sha-changed" }, first.documents[1]] })).toBe(false);
    expect(sameUnpublishImpactSources(first, { ...first, documents: first.documents.slice(0, 1) })).toBe(false);
    expect(sameUnpublishImpactSources(first, { ...first, omissions: [] })).toBe(false);
    expect(sameUnpublishImpactSources(first, { ...first, warnings: ["new warning"] })).toBe(false);
  });
});
