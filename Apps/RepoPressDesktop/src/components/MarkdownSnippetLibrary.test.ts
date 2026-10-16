import { beforeEach, describe, expect, it } from "vitest";
import { MARKDOWN_CUSTOM_SNIPPETS_STORAGE_KEY, readStoredMarkdownSnippets } from "./MarkdownSnippetLibrary";

describe("MarkdownSnippetLibrary storage", () => {
  beforeEach(() => window.localStorage.clear());

  it("sanitizes optional fields and rejects malformed persisted snippets", () => {
    window.localStorage.setItem(MARKDOWN_CUSTOM_SNIPPETS_STORAGE_KEY, JSON.stringify({
      site: [
        { id: "ok", label: "  可用  ", shortcut: " /提示 ", kind: "snippet", template: "正文", description: "  说明  ", selectionToken: "正文" },
        { id: "bad-description", label: "坏", shortcut: "bad", kind: "snippet", template: "正文", description: { unsafe: true } },
        { id: "bad-token", label: "坏", shortcut: "bad-token", kind: "snippet", template: "正文", selectionToken: 42 },
        { id: "tutorial", label: "覆盖内置", shortcut: "tutorial", kind: "snippet", template: "正文" },
      ],
    }));
    expect(readStoredMarkdownSnippets("site")).toEqual([{
      id: "ok", label: "可用", shortcut: "提示", kind: "snippet", template: "正文", description: "说明", selectionToken: "正文",
    }]);
  });
});
