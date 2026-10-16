import { describe, expect, it } from "vitest";
import { getMetadataDiagnostics, MAX_METADATA_CHECK_BYTES } from "./metadataDiagnostics";

describe("getMetadataDiagnostics", () => {
  it("reports only local field guidance for YAML, including title, summary, slug, permalink, and cover", () => {
    const report = getMetadataDiagnostics('---\r\ntitle: "short"\r\ndescription: "tiny"\r\nslug: "Bad slug"\r\npermalink: "post?a"\r\ncover: " cover.jpg "\r\n---\r\nBody');
    expect(report.limited).toBe(false);
    expect(report.issues.map((entry) => entry.field)).toEqual(expect.arrayContaining(["title", "description", "slug", "permalink", "cover"]));
    expect(report.issues.find((entry) => entry.id === "permalink-syntax")?.message).toContain("站点配置");
  });

  it("supports TOML and turns parser problems into a read-only structural route", () => {
    const toml = '+++\ntitle = "A useful article title that is long enough"\ndescription = "A description with enough characters to avoid the usual local suggestion range entirely."\n+++\nText';
    expect(getMetadataDiagnostics(toml).issues).toEqual([]);
    const malformed = '---\ntitle: [not safely editable]\n---\nText';
    const report = getMetadataDiagnostics(malformed);
    expect(report.issues).toMatchObject([{ field: "title", readOnly: true, id: "front-matter-structure" }]);
  });

  it("does not parse indefinitely or throw for abnormal and missing Front Matter input", () => {
    expect(getMetadataDiagnostics("plain body").issues).toMatchObject([{ id: "front-matter-missing", field: "title" }]);
    expect(getMetadataDiagnostics("😀").checkedBytes).toBe(4);
    const huge = `---\ntitle: "x"\n---\n${"a".repeat(MAX_METADATA_CHECK_BYTES + 1)}`;
    expect(getMetadataDiagnostics(huge)).toMatchObject({ limited: true, checkedBytes: 0 });
    expect(getMetadataDiagnostics("😀".repeat(Math.ceil(MAX_METADATA_CHECK_BYTES / 2)))).toMatchObject({ limited: true, checkedBytes: 0 });
  });
});
