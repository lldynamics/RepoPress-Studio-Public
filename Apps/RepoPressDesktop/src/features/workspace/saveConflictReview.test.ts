import { describe, expect, it, vi } from "vitest";
import { SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES, SAVE_CONFLICT_REVIEW_TOTAL_LIMIT_BYTES, utf8ByteLength, validateSaveConflictMergedTextBudget, validateSaveConflictReviewBudget, type SaveConflictReviewSnapshot } from "./saveConflictReview";

function review(overrides: Partial<SaveConflictReviewSnapshot> = {}): SaveConflictReviewSnapshot {
  return { documentKey: "document-1", relativePath: "posts/article.md", baselineText: "baseline", localText: "local", diskText: "disk", diskSha256: "a".repeat(64), ...overrides };
}

describe("save conflict review budget", () => {
  it("counts actual UTF-8 bytes rather than JavaScript code units", () => {
    expect(utf8ByteLength("a😀中")).toBe(8);
  });

  it("accepts bounded complete review sources", () => {
    const result = validateSaveConflictReviewBudget(review());
    expect(result).toEqual({ ok: true, bytes: { baseline: 8, local: 5, disk: 4, total: 17 } });
  });

  it("rejects a source over 256 KiB without a truncation value", () => {
    const encode = vi.spyOn(TextEncoder.prototype, "encode");
    const result = validateSaveConflictReviewBudget(review({ localText: "x".repeat(SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES + 1) }));
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.message).toContain("256 KiB");
    expect(encode).not.toHaveBeenCalled();
    encode.mockRestore();
  });

  it("exports the combined three-source budget for gateway parity", () => {
    expect(SAVE_CONFLICT_REVIEW_TOTAL_LIMIT_BYTES).toBe(768 * 1024);
  });

  it("rejects an oversized merge before encoding it", () => {
    const encode = vi.spyOn(TextEncoder.prototype, "encode");
    expect(validateSaveConflictMergedTextBudget("x".repeat(SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES + 1)).ok).toBe(false);
    expect(encode).not.toHaveBeenCalled();
    encode.mockRestore();
  });
});
