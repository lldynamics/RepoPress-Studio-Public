import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MarkdownWritingToolbar } from "./MarkdownWritingToolbar";

const baseProps = { value: "hello", selection: { from: 0, to: 5 }, disabled: false } as const;

describe("MarkdownWritingToolbar", () => {
  let host: HTMLDivElement | undefined;
  let root: ReturnType<typeof createRoot> | undefined;

  afterEach(() => {
    act(() => root?.unmount());
    host?.remove();
    root = undefined;
    host = undefined;
  });

  function renderToolbar(overrides: Partial<Parameters<typeof MarkdownWritingToolbar>[0]> = {}) {
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
    const onFormat = overrides.onFormat ?? vi.fn();
    act(() => { root?.render(createElement(MarkdownWritingToolbar, { ...baseProps, ...overrides, onFormat })); });
    return { onFormat, toolbar: host.querySelector<HTMLElement>("[role=toolbar]")! };
  }

  it("calls the selected format and leaves the incoming selection untouched", () => {
    const { onFormat, toolbar } = renderToolbar();
    const button = toolbar.querySelector<HTMLButtonElement>("button[aria-label='粗体']")!;
    act(() => { button.click(); });
    expect(onFormat).toHaveBeenCalledWith("bold");
    expect(toolbar.dataset.selection).toBe("0:5");
  });

  it("preserves a callback-selected focus target after a menu action", () => {
    const target = document.createElement("button");
    document.body.append(target);
    const { toolbar } = renderToolbar({ itemIds: ["heading", "bold", "codeBlock"] as const, onFormat: () => target.focus() });
    const menuButton = toolbar.querySelector<HTMLButtonElement>("button[aria-label='代码块']")!;
    act(() => { toolbar.querySelector<HTMLDetailsElement>("details")!.querySelector("summary")!.click(); menuButton.click(); });
    expect(document.activeElement).toBe(target);
    target.remove();
  });

  it("keeps an explicit empty preference empty and exposes every enabled overflow command", () => {
    const empty = renderToolbar({ itemIds: [] });
    expect(empty.toolbar.querySelector("button[aria-label='粗体']")).toBeNull();
    expect(Array.from(empty.toolbar.querySelectorAll("summary")).some((summary) => summary.textContent?.includes("工具栏选项"))).toBe(true);
    act(() => root?.unmount());
    host?.remove();
    const all = renderToolbar({ itemIds: ["bold", "italic", "strike", "code", "link", "heading", "quote", "unorderedList", "orderedList", "taskList", "codeBlock", "horizontalRule"] as const });
    expect(all.toolbar.querySelector("button[aria-label='代码块']")).toBeTruthy();
    expect(all.toolbar.querySelector("button[aria-label='删除线']")).toBeTruthy();
  });

  it("disables format actions without disabling menu navigation", () => {
    const { toolbar } = renderToolbar({ disabled: true });
    expect(toolbar.querySelector<HTMLButtonElement>("button[aria-label='粗体']")?.disabled).toBe(true);
    expect(Array.from(toolbar.querySelectorAll("summary")).some((summary) => summary.textContent?.includes("工具栏选项"))).toBe(true);
  });

  it("closes a menu with Escape and restores focus to its summary", async () => {
    const { toolbar } = renderToolbar();
    const menu = toolbar.querySelector<HTMLDetailsElement>("details")!;
    const summary = menu.querySelector<HTMLElement>("summary")!;
    act(() => { summary.click(); });
    expect(menu.open).toBe(true);
    act(() => { menu.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); });
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(menu.open).toBe(false);
    expect(document.activeElement).toBe(summary);
  });
});
