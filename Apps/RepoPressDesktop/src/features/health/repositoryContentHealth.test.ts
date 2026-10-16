import { describe, expect, it } from "vitest";
import { analyzeRepositoryContentHealth } from "./repositoryContentHealth";

const doc = (relativePath: string, text: string) => ({ relativePath, displayName: relativePath.split("/")[relativePath.split("/").length - 1], text, byteSize: text.length, sha256: "sha" });
const snapshot = (documents: ReturnType<typeof doc>[], extra: Record<string, unknown> = {}) => ({ documents, totalFiles: documents.length, scannedFiles: documents.length, scannedBytes: documents.reduce((n, d) => n + d.byteSize, 0), omittedFiles: 0, truncated: false, omissions: [], warnings: [], ...extra });

describe("repository content health", () => {
  it("keeps UTF-16 ranges and ignores front matter and code", () => {
    const text = "---\ntitle: https://ignored\n---\n`https://ignored`\n😀 ![](x.png)\nhttps://real.example";
    const report = analyzeRepositoryContentHealth(snapshot([doc("a.md", text)]));
    const bare = report.issues.find((item) => item.code === "bare-url");
    expect(bare?.range.from).toBe(text.lastIndexOf("https://real.example"));
    expect(report.issues.some((item) => item.code === "image-alt")).toBe(true);
  });
  it("reports unsafe and empty front matter", () => {
    const report = analyzeRepositoryContentHealth(snapshot([doc("a.md", "---\ntags: {bad: value}\n---\nbody") , doc("b.md", "---\ntitle: x\nslug: \n---\nbody") ]));
    expect(report.issues.some((item) => item.code === "frontmatter-unsafe")).toBe(true);
    expect(report.issues.some((item) => item.code === "frontmatter-slug-empty")).toBe(true);
  });
  it("resolves relative links and reports missing targets, while ignoring external links", () => {
    const source = "[ok](./guide.md#part) [missing](../no%20file.md?q=1) [web](https://example.com/x)";
    const report = analyzeRepositoryContentHealth(snapshot([doc("content/a.md", source), doc("content/guide.md", "# Guide") ]));
    expect(report.issues.filter((item) => item.code === "missing-relative-link")).toHaveLength(1);
  });
  it("resolves root absolute links and reports root escape without probing", () => {
    const source = "[root](/guide.md) [escape](../../outside.md)";
    const report = analyzeRepositoryContentHealth(snapshot([doc("content/a.md", source), doc("guide.md", "# Guide") ]));
    expect(report.issues.some((item) => item.code === "missing-relative-link")).toBe(false);
    expect(report.issues.some((item) => item.code === "unsafe-relative-link" && item.severity === "warning")).toBe(true);
  });
  it("reports duplicate title and routes, supports wiki diagnostics and editor overlay", () => {
    const base = snapshot([doc("a.md", "---\ntitle: Same\nslug: route\n---\n[[Missing]]"), doc("b.md", "---\ntitle: Same\nslug: route\n---\nbody")]);
    const report = analyzeRepositoryContentHealth(base, { relativePath: "a.md", text: "---\ntitle: Changed\nslug: route\n---\nbody" });
    expect(report.issues.some((item) => item.code === "duplicate-slug" && item.source === "editor")).toBe(true);
    expect(report.issues.some((item) => item.code === "duplicate-title")).toBe(false);
    expect(report.issues.some((item) => item.code === "missing-internal-link")).toBe(false);
  });
  it("marks omissions partial and never presents a clean report", () => {
    const report = analyzeRepositoryContentHealth(snapshot([doc("a.md", "body")], { omittedFiles: 2, omissions: [
      { relativePath: null, code: "budget", message: "file exceeded scan budget" },
      { relativePath: null, code: "budget", message: "file exceeded scan budget" },
    ] }));
    expect(report.partial).toBe(true);
    expect(report.issues.some((item) => item.code === "source-unavailable")).toBe(true);
    expect(report.issues.find((item) => item.code === "source-unavailable")?.relativePath).toBeNull();
    const omissionIds = report.issues.filter((item) => item.source === "scan").map((item) => item.id);
    expect(new Set(omissionIds).size).toBe(omissionIds.length);
  });
  it("sorts deterministically", () => {
    const input = snapshot([doc("z.md", "---\nslug: same\n---\n"), doc("a.md", "---\nslug: same\n---\n")]);
    const first = analyzeRepositoryContentHealth(input); const second = analyzeRepositoryContentHealth({ ...input, documents: [...input.documents].reverse() });
    expect(first.issues).toEqual(second.issues);
  });
  it("bounds a single document with more findings than the report limit", () => {
    const text = Array.from({ length: 5_100 }, (_, index) => `[missing](missing-${index}.md)`).join("\n");
    const report = analyzeRepositoryContentHealth(snapshot([doc("a.md", text)]));
    expect(report.issues).toHaveLength(5_000);
    expect(report.truncatedIssues).toBe(true);
  });
});
