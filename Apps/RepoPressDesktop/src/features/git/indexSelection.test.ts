import { describe, expect, it } from "vitest";
import { indexActionEligible, indexStatusLabel } from "./indexSelection";

describe("git index selection", () => {
  it("maps porcelain status to stage and unstage actions", () => {
    expect(indexActionEligible({ status: " M", relativePath: "a.md", sourcePath: null }, "stage")).toBe(true);
    expect(indexActionEligible({ status: "M ", relativePath: "b.md", sourcePath: null }, "unstage")).toBe(true);
    expect(indexActionEligible({ status: "??", relativePath: "c.md", sourcePath: null }, "stage")).toBe(true);
    expect(indexActionEligible({ status: "??", relativePath: "c.md", sourcePath: null }, "unstage")).toBe(false);
    expect(indexActionEligible({ status: "R ", relativePath: "new.md", sourcePath: "old.md" }, "unstage")).toBe(false);
    expect(indexStatusLabel("M ")).toBe("已暂存");
    expect(indexStatusLabel("??")).toBe("未跟踪");
  });
});
