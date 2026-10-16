import { describe, expect, it } from "vitest";
import { applyMarkdownFindReplacePreview, findInMarkdownScope, freezeMarkdownSelection, markdownBodyRange, planMarkdownFindReplacePreview } from "./markdownFindReplacePreview";

describe("markdown find/replace preview", () => {
  it("excludes YAML front matter and preserves CRLF and Unicode body text", () => {
    const value = "---\r\ntitle: needle\r\n---\r\n你好 needle\r\nneedle";
    expect(markdownBodyRange(value)).toEqual({ from: 25, to: value.length });
    const plan = planMarkdownFindReplacePreview({ value, documentKey: "doc:1", scope: "body", selection: null, query: "needle", replacement: "替换" });
    expect(plan.preview).toMatchObject({ replacementCount: 2, originalText: "你好 needle\r\nneedle", proposedText: "你好 替换\r\n替换" });
    expect(applyMarkdownFindReplacePreview(plan.preview!, value, "doc:1").edit?.text).toBe("---\r\ntitle: needle\r\n---\r\n你好 替换\r\n替换");
  });

  it("freezes a body selection and rejects a stale value or document identity", () => {
    const value = "---\ntitle: no\n---\nkeep needle needle";
    const selection = freezeMarkdownSelection(value, { from: 21, to: value.length }, "first");
    const plan = planMarkdownFindReplacePreview({ value, documentKey: "first", scope: "selection", selection, query: "needle", replacement: "done" });
    expect(plan.preview?.replacementCount).toBe(2);
    expect(applyMarkdownFindReplacePreview(plan.preview!, value + "!", "first").error).toContain("已失效");
    expect(applyMarkdownFindReplacePreview(plan.preview!, value, "second").error).toContain("已失效");
    expect(applyMarkdownFindReplacePreview(plan.preview!, value, "first", true).error).toContain("只读");
  });

  it("uses literal replacement text and has explicit bounds instead of partial replacement", () => {
    const plan = planMarkdownFindReplacePreview({ value: "a a", scope: "body", selection: null, query: "a", replacement: "$1" });
    expect(plan.preview).toMatchObject({ proposedText: "$1 $1", replacementCount: 2 });
    expect(findInMarkdownScope("x".repeat(256 * 1024 + 1), { from: 0, to: 256 * 1024 + 1 }, "x").error).toContain("无法安全预览");
  });

  it("uses the shared TOML parser and refuses an ambiguous body scope", () => {
    const toml = "+++\r\ntitle = 'needle'\r\n+++\r\nneedle";
    expect(markdownBodyRange(toml)).toEqual({ from: 28, to: toml.length });
    const malformed = "---\ntitle: needle\n---oops\nneedle";
    expect(planMarkdownFindReplacePreview({ value: malformed, scope: "body", selection: null, query: "needle", replacement: "done" }).error).toContain("无法确认正文范围");
  });

  it("rejects a document before attempting Front Matter parsing or preview work", () => {
    const oversized = "x".repeat(512 * 1024 + 1);
    expect(planMarkdownFindReplacePreview({ value: oversized, scope: "body", selection: null, query: "x", replacement: "y" }).error).toContain("文稿超过");
  });

  it("keeps whole-word matching scoped to the frozen selection", () => {
    const value = "cat scatter cat\ncat";
    const selection = freezeMarkdownSelection(value, { from: 12, to: value.length }, "one");
    const plan = planMarkdownFindReplacePreview({ value, documentKey: "one", scope: "selection", selection, query: "cat", replacement: "dog", options: { wholeWord: true } });
    expect(plan.preview).toMatchObject({ originalText: "cat\ncat", proposedText: "dog\ndog", replacementCount: 2 });
  });
});
