import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { TextRange } from "../features/writing/markdownWriting";
import { MarkdownOutlinePanel } from "./MarkdownOutlinePanel";

let root: Root | undefined;
let host: HTMLDivElement | undefined;

afterEach(() => { act(() => root?.unmount()); host?.remove(); root = undefined; host = undefined; });

function renderPanel(value: string, selection: TextRange, onLocate = vi.fn(), onClose = vi.fn(), documentKey = "doc-1") {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  act(() => { root?.render(createElement(MarkdownOutlinePanel, { value, selection, documentKey, onLocate, onClose })); });
  return { onLocate, onClose };
}

describe("MarkdownOutlinePanel", () => {
  it("marks the heading at the cursor and locates its heading text", () => {
    const { onLocate: locate, onClose } = renderPanel("# 第一章\n正文\n## 第二章", { from: 14, to: 14 });
    expect(host?.querySelector('[aria-current="location"]')?.textContent).toContain("第二章");
    const second = [...(host?.querySelectorAll(".markdown-outline-panel__item") ?? [])][1] as HTMLButtonElement;
    act(() => second.click());
    expect(locate).toHaveBeenCalledWith({ from: 9, to: 15 }, "# 第一章\n正文\n## 第二章");
    act(() => host?.querySelector<HTMLButtonElement>(".markdown-outline-panel__close")?.click());
    expect(onClose).toHaveBeenCalledOnce();
  });

  it("collapses descendants while retaining the next sibling", () => {
    renderPanel("# A\n## A.1\n### A.1.a\n## A.2\n# B", { from: 0, to: 0 });
    const toggle = host?.querySelector<HTMLButtonElement>('[aria-label="折叠A"]');
    act(() => toggle?.click());
    expect([...host?.querySelectorAll(".markdown-outline-panel__title") ?? []].map((node) => node.textContent)).toEqual(["A", "B"]);
  });

  it("does not carry collapse state to a changed document or renamed heading", () => {
    const value = "# Alpha\n## Child\n# Other";
    renderPanel(value, { from: 0, to: 0 });
    act(() => host?.querySelector<HTMLButtonElement>('[aria-label="折叠Alpha"]')?.click());
    act(() => root?.render(createElement(MarkdownOutlinePanel, { value: "# Bravo\n## Child\n# Other", selection: { from: 0, to: 0 }, documentKey: "doc-2", onLocate: vi.fn(), onClose: vi.fn() })));
    expect([...host?.querySelectorAll(".markdown-outline-panel__title") ?? []].map((node) => node.textContent)).toEqual(["Bravo", "Child", "Other"]);
  });
});
