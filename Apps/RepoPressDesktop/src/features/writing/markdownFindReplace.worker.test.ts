import { describe, expect, it } from "vitest";
import { executeMarkdownFindReplaceWorker } from "./markdownFindReplace.worker";
describe("markdown find/replace worker", () => {
  it("keeps regular-expression captures in a bounded preview", () => expect(executeMarkdownFindReplaceWorker({ requestId: 1, kind: "preview", text: "ab-12", query: "([a-z]+)-(\\d+)", replacement: "$2:$1", options: { regularExpression: true } })).toMatchObject({ error: null, proposedText: "12:ab", replacementCount: 1 }));
  it("replaces the next match only within its supplied scope", () => expect(executeMarkdownFindReplaceWorker({ requestId: 2, kind: "replaceCurrentOrNext", text: "a b a", query: "a", replacement: "x", selection: { from: 2, to: 2 }, options: {} })).toMatchObject({ proposedText: "a b x", replacementCount: 1, selection: { from: 4, to: 5 } }));
  it("rejects malformed and over-budget input", () => {
    expect(executeMarkdownFindReplaceWorker({ requestId: 3, kind: "inspect", text: "abc", query: "(", options: { regularExpression: true } }).error).toBe("正则表达式无效");
    expect(executeMarkdownFindReplaceWorker({ requestId: 4, kind: "inspect", text: "a".repeat(256 * 1024 + 1), query: "a", options: {} }).error).toContain("无法安全预览");
  });
});
