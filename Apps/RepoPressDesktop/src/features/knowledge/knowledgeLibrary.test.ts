import { describe, expect, it } from "vitest";
import { clampProgress, defaultArchivePath, defaultExportPath, isExportPlanExpired, normalizeKnowledgeItem, safeSourceUrl } from "./knowledgeLibrary";
describe("knowledge library helpers", () => {
  it("clamps progress", () => { expect(clampProgress(-2)).toBe(0); expect(clampProgress(101)).toBe(100); });
  it("only permits credential-free web URLs", () => {
    expect(safeSourceUrl("javascript:alert(1)")).toBeNull();
    expect(safeSourceUrl("https://user:secret@example.com/a")).toBeNull();
    expect(safeSourceUrl("https://example.com/a#private-fragment")).toBe("https://example.com/a");
  });
  it("creates stable export paths", () => { expect(defaultExportPath({ title: "中文 入门" })).toBe("knowledge/中文-入门.md"); expect(defaultExportPath({ title: "!!!" })).toBe("knowledge/knowledge-item.md"); });
  it("creates archive paths and normalizes legacy objects", () => { expect(defaultArchivePath({ title: "中文 入门" }, "mhtml")).toBe("knowledge/中文-入门.mhtml"); const item = normalizeKnowledgeItem({ summary: { itemId: "1", title: "T", sourceKind: "text", sourceName: "x", sourceUrl: null, byteSize: 1, createdAtEpochSeconds: 1, updatedAtEpochSeconds: 1, readingProgressPercent: 0, allowsLocalSemanticIndex: false, archive: undefined as never }, text: "body" }); expect(item.text).toBe("body"); expect(item.archive).toBeNull(); });
  it("recognizes archive plan expiry", () => { expect(isExportPlanExpired({ expiresAtEpochSeconds: 1 }, 1001)).toBe(true); expect(isExportPlanExpired({ expiresAtEpochSeconds: 2 }, 1001)).toBe(false); });
});
