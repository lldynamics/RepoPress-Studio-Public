import { describe, expect, it } from "vitest";
import { activeMarkdownOutlineItemId, presentMarkdownOutline, visibleMarkdownOutlineItems } from "./markdownOutlinePresentation";

describe("markdown outline presentation", () => {
  it("tracks nested visibility and keeps following siblings visible", () => {
    const { items } = presentMarkdownOutline("# A\n## A.1\n### A.1.a\n## A.2\n# B");
    expect(visibleMarkdownOutlineItems(items, new Set([items[0].id])).map((item) => item.title)).toEqual(["A", "B"]);
    expect(visibleMarkdownOutlineItems(items, new Set([items[1].id])).map((item) => item.title)).toEqual(["A", "A.1", "A.2", "B"]);
  });

  it("uses heading position for duplicate and Chinese titles", () => {
    const { items } = presentMarkdownOutline("# 重复\n# 重复");
    expect(items[0].id).not.toBe(items[1].id);
    expect(activeMarkdownOutlineItemId(items, { from: items[1].from, to: items[1].from })).toBe(items[1].id);
  });

  it("reports bounded partial results", () => {
    const value = Array.from({ length: 501 }, (_, index) => `# ${index}`).join("\n");
    const result = presentMarkdownOutline(value);
    expect(result.items).toHaveLength(500);
    expect(result.isPartial).toBe(true);
    expect(result.totalCount).toBe(501);
    const omitted = value.lastIndexOf("# 500");
    expect(activeMarkdownOutlineItemId(result.items, { from: omitted, to: omitted })).toBeNull();
  });
});
