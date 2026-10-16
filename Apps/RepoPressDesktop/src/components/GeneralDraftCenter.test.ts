import { describe, expect, it } from "vitest";
import { generalDraftFilenameStem, suggestedGeneralDraftPaths, withMarkdownExtension } from "../features/writing/generalDraftTransfer";
import componentSource from "./GeneralDraftCenter.tsx?raw";

describe("GeneralDraftCenter transfer defaults", () => {
  it("creates safe Markdown paths without relying on a site-specific content convention", () => {
    expect(generalDraftFilenameStem(" ../危险/标题: 草稿? ")).toBe("危险-标题-草稿");
    expect(withMarkdownExtension(" content/drafts/hello ")).toBe("content/drafts/hello.md");
    expect(withMarkdownExtension("content/drafts/hello.MD")).toBe("content/drafts/hello.MD");
    expect(suggestedGeneralDraftPaths([{ draftId: "a", title: "新文章" }], null)).toEqual({ a: "drafts/新文章.md" });
  });

  it("resolves same-batch collisions deterministically, independent of selection order", () => {
    const entries = [{ draftId: "b", title: "Same title" }, { draftId: "a", title: "Same title" }];
    expect(suggestedGeneralDraftPaths(entries, "content")).toEqual({ a: "content/drafts/Same-title.md", b: "content/drafts/Same-title-2.md" });
    expect(suggestedGeneralDraftPaths([...entries].reverse(), "content")).toEqual({ a: "content/drafts/Same-title.md", b: "content/drafts/Same-title-2.md" });
  });

  it("makes the plan stale when its bound UI context changes and keeps transfer text rendering safe", () => {
    expect(componentSource).toContain("planContextRef.current !== planContext");
    expect(componentSource).toContain("跨站点通过通用草稿中转，不代表自动搬附件或改写 front matter");
    expect(componentSource).toContain("必须先保存当前文章");
    expect(componentSource).not.toContain("dangerouslySetInnerHTML");
  });
});
