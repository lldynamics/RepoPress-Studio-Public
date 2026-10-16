import { describe, expect, it } from "vitest";
import { compareDraftVersion, draftVersionReasonLabel, formatDraftHistorySize } from "./draftHistory";

describe("draft history comparison", () => {
  it("handles equal, additions, removals, edits and Chinese text", () => {
    expect(compareDraftVersion("相同", "相同")).toMatchObject({ addedCount: 0, removedCount: 0, unchangedCount: 1, truncated: false });
    expect(compareDraftVersion("a\nb", "a")).toMatchObject({ addedCount: 1, removedCount: 0, unchangedCount: 1 });
    expect(compareDraftVersion("a", "a\nb")).toMatchObject({ addedCount: 0, removedCount: 1, unchangedCount: 1 });
    const changed = compareDraftVersion("新", "旧");
    expect(changed.addedCount).toBe(1); expect(changed.removedCount).toBe(1); expect(changed.lines.map((line) => line.kind)).toEqual(["added", "removed"]);
  });
  it("defends unknown reasons and bounds expensive comparisons", () => {
    expect(draftVersionReasonLabel("unexpected")).toBe("未知版本");
    expect(draftVersionReasonLabel("deleted")).toBe("删除前");
    const huge = Array.from({ length: 401 }, (_, i) => String(i)).join("\n");
    expect(compareDraftVersion(huge, "small")).toMatchObject({ truncated: true, lines: [] });
  });
  it("formats sizes predictably", () => { expect(formatDraftHistorySize(0)).toBe("0 B"); expect(formatDraftHistorySize(1024)).toBe("1.0 KiB"); });
});
