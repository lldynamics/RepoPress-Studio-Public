import { describe, expect, it } from "vitest";
import type { ImageReferenceInput } from "../../contracts/imageReferences";
import { analyzeRepositoryImageReferences } from "./repositoryImageReferences";

function input(text: string, extra: Partial<ImageReferenceInput> = {}): ImageReferenceInput {
  return {
    sources: { documents: [{ relativePath: "content/posts/article.md", displayName: "article", text, byteSize: text.length, sha256: "a".repeat(64) }], totalFiles: 1, scannedFiles: 1, scannedBytes: text.length, omittedFiles: 0, truncated: false, omissions: [], warnings: [] },
    images: { images: [{ relativePath: "static/images/封面 (1).png", fileName: "封面", byteSize: 1, mimeType: "image/png", width: null, height: null, sha256: "b".repeat(64) }, { relativePath: "content/posts/local.png", fileName: "local", byteSize: 1, mimeType: "image/png", width: null, height: null, sha256: "c".repeat(64) }], scannedEntries: 2, scannedBytes: 2, omittedFiles: 0, truncated: false, warnings: [] },
    repository: { siteKind: "hugo", contentRoot: "content" },
    ...extra,
  };
}

describe("repository image references", () => {
  it("maps public and document-relative paths, including encoded Unicode and parentheses", () => {
    const report = analyzeRepositoryImageReferences(input("![封面](/images/%E5%B0%81%E9%9D%A2%20%281%29.png)\n![本地](local.png)"));
    expect(report.references.map((finding) => [finding.resolvedPath, finding.status, finding.line])).toEqual([
      ["static/images/封面 (1).png", "matched", 1], ["content/posts/local.png", "matched", 2],
    ]);
    expect(report.imagesWithoutReferences).toEqual([]);
  });

  it.each([
    ["astro", null, "/images/a.png", "public/images/a.png"], ["vitepress", null, "/images/a.png", "docs/public/images/a.png"],
    ["jekyll", null, "/assets/images/a.png", "assets/images/a.png"], ["jekyll-or-hexo", "source/_posts", "/images/a.png", "source/images/a.png"],
    ["foam", null, "/attachments/a.png", "attachments/a.png"], ["quartz", null, "/attachments/a.png", "content/attachments/a.png"],
  ])("reverses %s importer public mapping", (siteKind, contentRoot, target, expected) => {
    const report = analyzeRepositoryImageReferences(input(`![x](${target})`, { repository: { siteKind, contentRoot }, images: { images: [{ relativePath: expected, fileName: "a", byteSize: 1, mimeType: "image/png", width: null, height: null, sha256: "d".repeat(64) }], scannedEntries: 1, scannedBytes: 1, omittedFiles: 0, truncated: false, warnings: [] } }));
    expect(report.references[0]).toMatchObject({ resolvedPath: expected, status: "matched" });
  });

  it("parses reference-style images and escaped destinations without scanning excluded syntax", () => {
    const text = [
      "---", "hero: ![头部](local.png)", "---", "![空][] ![文字][cover] ![括号](local\\(copy\\).png \"title\")", "[cover]: /images/%E5%B0%81%E9%9D%A2%20%281%29.png", "[空]: local.png",
      "`![代码](local.png)`", "<!-- ![注释](local.png) -->", "<img src=\"local.png\"> ![[local.png]]", "```md", "![围栏](local.png)", "```",
    ].join("\r\n");
    const report = analyzeRepositoryImageReferences(input(text, { images: { images: [{ relativePath: "static/images/封面 (1).png", fileName: "a", byteSize: 1, mimeType: "image/png", width: null, height: null, sha256: "a".repeat(64) }, { relativePath: "content/posts/local.png", fileName: "b", byteSize: 1, mimeType: "image/png", width: null, height: null, sha256: "b".repeat(64) }], scannedEntries: 2, scannedBytes: 2, omittedFiles: 0, truncated: false, warnings: [] } }));
    expect(report.references).toHaveLength(3);
    expect(report.references.map((finding) => finding.line)).toEqual([4, 4, 4]);
    expect(report.references[0]).toMatchObject({ alt: "空", resolvedPath: "content/posts/local.png" });
    expect(report.references[1]).toMatchObject({ resolvedPath: "static/images/封面 (1).png" });
    expect(report.references[2]).toMatchObject({ status: "unverified", resolvedPath: "content/posts/local(copy).png" });
  });

  it("exposes an exact target range only for eligible inline image syntax", () => {
    const text = [
      "---", "hero: ![front](local.png)", "---",
      "![first](missing.png \"keep title\") ![second](missing.png)",
      "![reference][later]", "[later]: local.png", "`![code](local.png)`",
    ].join("\n");
    const report = analyzeRepositoryImageReferences(input(text));
    expect(report.references).toHaveLength(3);
    const [first, second, reference] = report.references;
    expect(first.repairTarget).toEqual({ from: text.indexOf("missing.png"), to: text.indexOf("missing.png") + "missing.png".length, expectedText: "missing.png" });
    expect(second.repairTarget).toEqual({ from: text.lastIndexOf("missing.png"), to: text.lastIndexOf("missing.png") + "missing.png".length, expectedText: "missing.png" });
    expect(reference.repairTarget).toBeUndefined();
    const replacement = "./%E6%9B%BF%E6%8D%A2%20%281%29.png";
    const next = text.slice(0, first.repairTarget!.from) + replacement + text.slice(first.repairTarget!.to);
    expect(next).toContain(`![first](${replacement} \"keep title\")`);
    expect(next).toContain("![second](missing.png)");
    expect(next).toContain("hero: ![front](local.png)");
  });

  it("never exposes repair tokens in BOM YAML/TOML front matter and rejects a malformed preamble", () => {
    const validPreambles = [
      "\ufeff---\nimage: '![x](old.png)'\n---\n![body](old.png)",
      "+++\nimage = '![x](old.png)'\n+++\n![body](old.png)",
    ];
    for (const text of validPreambles) {
      const report = analyzeRepositoryImageReferences(input(text));
      expect(report.references.filter((finding) => finding.repairTarget)).toHaveLength(1);
      expect(report.references.find((finding) => finding.repairTarget)?.repairTarget?.from).toBe(text.lastIndexOf("old.png"));
    }
    expect(analyzeRepositoryImageReferences(input("---\nimage: '![x](old.png)'\n![body](old.png)")).references.every((finding) => !finding.repairTarget)).toBe(true);
  });

  it("keeps repair tokens only for fully confirmed body inline syntax", () => {
    const valid = "![first](old(1).png \"title\") ![second](old(1).png)";
    const validReport = analyzeRepositoryImageReferences(input(valid));
    expect(validReport.references.map((finding) => finding.repairTarget?.expectedText)).toEqual(["old(1).png", "old(1).png"]);
    for (const text of [
      "![bad](old.png unquoted title)",
      "![bad](old.png \"unterminated)",
      "![bad]({{ image }})",
      "<div>![bad](old.png)</div>",
      "{{ render(\"![bad](old.png)\") }}",
    ]) {
      const report = analyzeRepositoryImageReferences(input(text));
      expect(report.references.every((finding) => !finding.repairTarget)).toBe(true);
    }
  });

  it("fails closed for blockquote and list code containers that P22 only reports", () => {
    for (const text of [
      "> ~~~\n> ![quoted](old.png)\n> ~~~\n![body](old.png)",
      ">     ![quoted-indent](old.png)\n![body](old.png)",
      "- ~~~\n  ![list-fence](old.png)\n  ~~~\n![body](old.png)",
    ]) {
      const report = analyzeRepositoryImageReferences(input(text));
      expect(report.references.every((finding) => !finding.repairTarget)).toBe(true);
    }
    expect(analyzeRepositoryImageReferences(input("![body](old.png)")).references[0].repairTarget?.expectedText).toBe("old.png");
  });

  it("ignores escaped images, respects exact code delimiters and keeps the first reference definition", () => {
    const text = [
      "\\![escaped](local.png) ![kept][same]", "[same]: local.png", "[same]: /images/%E5%B0%81%E9%9D%A2%20%281%29.png",
      "`` one ` inner still code `` ![after](local.png)", "    ![indented](local.png)", "```", "![inside](local.png)", "```not-a-close", "![still inside](local.png)", "```", "![final](local.png)",
    ].join("\n");
    const report = analyzeRepositoryImageReferences(input(text));
    expect(report.references.map((finding) => [finding.alt, finding.line, finding.resolvedPath])).toEqual([
      ["kept", 1, "content/posts/local.png"], ["after", 4, "content/posts/local.png"], ["final", 11, "content/posts/local.png"],
    ]);
  });

  it("continues masking comments after an unclosed code delimiter", () => {
    const report = analyzeRepositoryImageReferences(input("`未闭合\n<!-- ![hidden](/hidden.png) -->\n![ok](local.png)"));
    expect(report.references).toHaveLength(1);
    expect(report.references[0]).toMatchObject({ alt: "ok", line: 3, resolvedPath: "content/posts/local.png" });
  });

  it("reports empty Alt and classifies external, unsupported, and unsafe targets without network access", () => {
    const report = analyzeRepositoryImageReferences(input("![](local.png)\n![remote](https://example.com/a.png)\n![cdn](//cdn.example/a.png)\n![data](data:image/png;base64,AAAA)\n![bad](../.git/config)\n![encoded](%2e%2e%2fsecret.png)\n![template]({{ image }})"));
    expect(report.references[0]).toMatchObject({ alt: "", status: "matched" });
    expect(report.references.slice(1).map((finding) => finding.status)).toEqual(["external", "external", "unsupported", "unsafe", "unsafe", "unsupported"]);
    expect(report.references.every((finding) => finding.status !== "matched" || finding.resolvedPath !== null)).toBe(true);
  });

  it("keeps unverified separate from disk absence and makes unused-image deletion claims impossible", () => {
    const report = analyzeRepositoryImageReferences(input("![not in manifest](missing.png)"));
    expect(report.references[0]).toMatchObject({ status: "unverified", resolvedPath: "content/posts/missing.png" });
    expect(report.imagesWithoutReferences).toEqual(["static/images/封面 (1).png", "content/posts/local.png"]);
    expect(report.warnings.join(" ")).toContain("不表示磁盘文件不存在");
    expect(report.warnings.join(" ")).toContain("不能据此删除文件");
  });

  it("replaces a same-path disk article or adds an editor-only article", () => {
    const replaced = analyzeRepositoryImageReferences(input("![disk](local.png)", { overlay: { relativePath: "content/posts/article.md", text: "![editor](/images/%E5%B0%81%E9%9D%A2%20%281%29.png)" } }));
    expect(replaced.references).toHaveLength(1);
    expect(replaced.references[0]).toMatchObject({ source: "editor", resolvedPath: "static/images/封面 (1).png" });
    const added = analyzeRepositoryImageReferences(input("", { overlay: { relativePath: "notes/current.md", text: "![editor](../content/posts/local.png)" } }));
    expect(added.scannedDocuments).toBe(2);
    expect(added.references.find((finding) => finding.source === "editor")).toMatchObject({ resolvedPath: "content/posts/local.png", status: "matched" });
  });

  it("omits a disk candidate when its same-path editor overlay is invalid or over budget", () => {
    const report = analyzeRepositoryImageReferences(input("![disk](local.png)", { overlay: { relativePath: "content/posts/article.md", text: "x".repeat(4 * 1024 * 1024 + 1) } }));
    expect(report.scannedDocuments).toBe(0);
    expect(report.references).toEqual([]);
    expect(report.omittedDocuments).toBe(1);
    expect(report.partial).toBe(true);
  });

  it("marks source budgets and result limits as partial with stable CRLF locations", () => {
    const documents = Array.from({ length: 1_002 }, (_, index) => ({ relativePath: `content/${index}.md`, displayName: String(index), text: index === 0 ? "\r\n![x](missing.png)" : "", byteSize: 0, sha256: "a".repeat(64) }));
    const report = analyzeRepositoryImageReferences(input("", { sources: { documents, totalFiles: documents.length, scannedFiles: documents.length, scannedBytes: 0, omittedFiles: 0, truncated: false, omissions: [], warnings: [] } }));
    expect(report.scannedDocuments).toBe(1_000);
    expect(report.omittedDocuments).toBe(2);
    expect(report.partial).toBe(true);
    expect(report.references[0]).toMatchObject({ line: 2, offset: 2 });
  });

  it("caps findings and per-document bytes without treating the partial report as complete", () => {
    const many = Array.from({ length: 2_001 }, () => "![](missing.png)").join("\n");
    const findings = analyzeRepositoryImageReferences(input(many));
    expect(findings.references).toHaveLength(2_000);
    expect(findings.truncated).toBe(true);
    expect(findings.partial).toBe(true);
    const oversized = analyzeRepositoryImageReferences(input("", { sources: { documents: [{ relativePath: "content/big.md", displayName: "big", text: "x".repeat(4 * 1024 * 1024 + 1), byteSize: 1, sha256: "a".repeat(64) }], totalFiles: 1, scannedFiles: 1, scannedBytes: 1, omittedFiles: 0, truncated: false, omissions: [], warnings: [] } }));
    expect(oversized.scannedDocuments).toBe(0);
    expect(oversized.omittedDocuments).toBe(1);
    expect(oversized.partial).toBe(true);
  });

  it("counts only documents entered before a finding-cap early stop", () => {
    const first = Array.from({ length: 2_001 }, () => "![](missing.png)").join("\n");
    const second = "![later](local.png)";
    const report = analyzeRepositoryImageReferences(input("", { sources: { documents: [
      { relativePath: "content/first.md", displayName: "first", text: first, byteSize: first.length, sha256: "a".repeat(64) },
      { relativePath: "content/second.md", displayName: "second", text: second, byteSize: second.length, sha256: "b".repeat(64) },
    ], totalFiles: 2, scannedFiles: 2, scannedBytes: first.length + second.length, omittedFiles: 0, truncated: false, omissions: [], warnings: [] } }));
    expect(report.references).toHaveLength(2_000);
    expect(report.scannedDocuments).toBe(1);
    expect(report.omittedDocuments).toBe(1);
    expect(report.references.some((finding) => finding.documentPath === "content/second.md")).toBe(false);
  });

  it("does not resolve truncated targets or decoded protocol disguises and bounds image input", () => {
    const longTarget = "local.png" + "x".repeat(2_100);
    const images = Array.from({ length: 1_001 }, (_, index) => ({ relativePath: `static/${index}.png`, fileName: String(index), byteSize: 1, mimeType: "image/png", width: null, height: null, sha256: "a".repeat(64) }));
    const report = analyzeRepositoryImageReferences(input(`![long](${longTarget})\n![encoded](%68ttps%3A%2F%2Fevil.example/x.png)\n![scheme](%68ttps%3Aevil.png)`, { images: { images, scannedEntries: images.length, scannedBytes: images.length, omittedFiles: 0, truncated: false, warnings: [] } }));
    expect(report.references[0]).toMatchObject({ status: "unsupported", resolvedPath: null });
    expect(report.references[1]).toMatchObject({ status: "unsafe", resolvedPath: null });
    expect(report.references[2]).toMatchObject({ status: "unsupported", resolvedPath: null });
    expect(report.imageCount).toBe(1_000);
    expect(report.partial).toBe(true);
    expect(report.truncated).toBe(true);
  });
});
