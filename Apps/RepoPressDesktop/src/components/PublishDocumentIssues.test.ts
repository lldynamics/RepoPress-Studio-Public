import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { PublishDocumentIssues, type PublishDocumentIssuesProps } from "./PublishDocumentIssues";

let root: Root;
let container: HTMLDivElement;
beforeAll(() => { Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true }); });
afterEach(() => { if (root) act(() => root.unmount()); container?.remove(); });
function render(props: PublishDocumentIssuesProps) {
  if (!container?.isConnected) { container = document.createElement("div"); document.body.append(container); root = createRoot(container); }
  act(() => root.render(createElement(PublishDocumentIssues, props)));
}
function buttons(label: string) { return [...container.querySelectorAll("button")].filter((button) => button.textContent === label); }
function inspect() { act(() => buttons("检查当前文稿")[0].click()); }

describe("PublishDocumentIssues", () => {
  it("checks only on request and sends the document snapshot and exact issue range", () => {
    const text = "# 稿件\n\n![](cover.png)\n";
    const onLocateIssue = vi.fn();
    render({ currentDocument: { relativePath: "content/a.md", text }, onLocateIssue });
    expect(buttons("定位")).toHaveLength(0);
    inspect();
    expect(buttons("定位").length).toBeGreaterThan(0);
    act(() => buttons("定位")[0].click());
    const [path, range, expectedText] = onLocateIssue.mock.calls[0];
    expect(path).toBe("content/a.md");
    expect(expectedText).toBe(text);
    expect(range.from).toBeGreaterThanOrEqual(text.indexOf("![]"));
    expect(range.to).toBeLessThanOrEqual(text.length);
    expect(container.textContent).toContain("第 3 行");
  });

  it("invalidates results when the buffer, file, or known link targets change", () => {
    const currentDocument = { relativePath: "a.md", text: "![](cover.png)", knownArticleTitles: ["a.md"] };
    render({ currentDocument }); inspect();
    expect(buttons("定位").length).toBeGreaterThan(0);
    render({ currentDocument: { ...currentDocument, text: "edited\n![](cover.png)" } });
    expect(buttons("定位")).toHaveLength(0);
    render({ currentDocument });
    expect(buttons("定位")).toHaveLength(0);
    inspect();
    render({ currentDocument: { ...currentDocument, relativePath: "b.md" } });
    expect(buttons("定位")).toHaveLength(0);
    inspect();
    render({ currentDocument: { ...currentDocument, relativePath: "b.md", knownArticleTitles: ["b.md"] } });
    expect(buttons("定位")).toHaveLength(0);
  });

  it("explains missing documents and keeps clean results limited to local Markdown checks", () => {
    render({ currentDocument: null });
    expect(buttons("检查当前文稿")[0].disabled).toBe(true);
    expect(container.textContent).toContain("请先打开一篇文稿");
    render({ currentDocument: { relativePath: "a.md", text: "# 完整标题\n\n普通正文。" } });
    inspect();
    expect(container.textContent).toContain("本次本地检查未发现常见 Markdown 问题");
    expect(container.textContent).not.toContain("可以发布");
    render({ currentDocument: { relativePath: "a.md", text: "![](cover.png)" } });
    inspect();
    expect(buttons("定位").every((button) => button.disabled)).toBe(true);
  });
});
