import { describe, expect, it } from "vitest";
import { replaceUnchangedSelection } from "./selectionReplacement";

describe("replaceUnchangedSelection", () => {
  it("uses CodeMirror-compatible UTF-16 offsets around emoji", () => {
    const source = "前😀旧文后";
    const result = replaceUnchangedSelection(source, { from: 1, to: 5, text: "😀旧文" }, "😀旧文", "✨新文");
    expect(result).toEqual({ text: "前✨新文后", selection: { from: 1, to: 4, text: "✨新文" } });
  });

  it("rejects a stale selection without changing the document", () => {
    expect(replaceUnchangedSelection("已变化", { from: 0, to: 2, text: "原文" }, "原文", "新文")).toBeNull();
  });
});
