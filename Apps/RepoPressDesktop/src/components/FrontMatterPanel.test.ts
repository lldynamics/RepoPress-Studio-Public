import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { FrontMatterPanel } from "./FrontMatterPanel";

let root: Root; let host: HTMLDivElement;
beforeAll(() => { Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true }); });
afterEach(() => { root?.unmount(); host?.remove(); });
function render(props: Parameters<typeof FrontMatterPanel>[0]) { host = document.createElement("div"); document.body.append(host); root = createRoot(host); act(() => root.render(createElement(FrontMatterPanel, props))); }
function input(label: string) { const node = [...host.querySelectorAll("label")].find((item) => item.textContent?.startsWith(label))?.querySelector("input"); if (!node) throw new Error(`missing ${label}`); return node as HTMLInputElement; }
function setInput(node: HTMLInputElement, value: string) { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(node, value); node.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" })); }

describe("FrontMatterPanel", () => {
  it("focuses a requested parsed field without changing text, and only edits the target field", async () => {
    const value = '---\ntitle: "Title long enough for local checks"\npermalink: "/old/"\ncover: "/cover.jpg"\nunknown: keep\n---\nBody';
    const onChange = vi.fn(); render({ value, selection: { from: value.length, to: value.length }, onChange, focusRequest: { field: "permalink", requestKey: 1, expectedText: value } });
    await act(async () => { await Promise.resolve(); });
    expect(document.activeElement).toBe(input("固定链接")); expect(onChange).not.toHaveBeenCalled();
    act(() => setInput(input("固定链接"), "/new/"));
    expect(onChange.mock.calls[0][0]).toContain('permalink: "/new/"'); expect(onChange.mock.calls[0][0]).toContain('cover: "/cover.jpg"'); expect(onChange.mock.calls[0][0]).toContain("unknown: keep\n---\nBody");
  });

  it("does not apply stale focus, never auto-adds missing Front Matter, and keeps read-only inputs protected", async () => {
    const text = "Body"; const onChange = vi.fn();
    render({ value: text, selection: { from: 0, to: 0 }, onChange, focusRequest: { field: "title", requestKey: 3, expectedText: "old" } });
    await act(async () => { await Promise.resolve(); });
    expect(document.activeElement).not.toBe(host.querySelector("button")); expect(onChange).not.toHaveBeenCalled();
    act(() => root.render(createElement(FrontMatterPanel, { value: text, selection: { from: 0, to: 0 }, onChange, focusRequest: { field: "title", requestKey: 4, expectedText: text }, disabled: true })));
    await act(async () => { await Promise.resolve(); });
    expect(onChange).not.toHaveBeenCalled(); expect((host.querySelector("button") as HTMLButtonElement).disabled).toBe(true);
  });

  it("routes malformed YAML to its read-only warning instead of attempting a repair", async () => {
    const value = "---\ntitle: [complex]\n---\nBody"; const onChange = vi.fn();
    render({ value, selection: { from: 0, to: 0 }, onChange, focusRequest: { field: "title", requestKey: 5, expectedText: value } });
    await act(async () => { await Promise.resolve(); });
    expect(host.querySelector(".front-matter-warning")).toBe(document.activeElement); expect(onChange).not.toHaveBeenCalled();
  });

  it("consumes a focus request, so closing the panel does not reopen it", async () => {
    const value = '---\ntitle: "A title long enough for local checking"\n---\nBody'; const request = { field: "title" as const, requestKey: 6, expectedText: value };
    render({ value, selection: { from: 0, to: 0 }, onChange: vi.fn(), focusRequest: request });
    await act(async () => { await Promise.resolve(); });
    act(() => (host.querySelector("button[aria-label='折叠 Front Matter 属性']") as HTMLButtonElement).click());
    act(() => root.render(createElement(FrontMatterPanel, { value, selection: { from: 0, to: 0 }, onChange: vi.fn(), focusRequest: { ...request } })));
    expect(host.querySelector("button[aria-label='折叠 Front Matter 属性']")).toBeNull();
  });
});
