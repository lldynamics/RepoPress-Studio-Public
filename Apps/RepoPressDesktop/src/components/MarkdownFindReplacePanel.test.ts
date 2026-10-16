import { act } from "react";
import { createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MarkdownFindReplacePanel } from "./MarkdownFindReplacePanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

class FindReplaceWorker {
  static mode: "respond" | "never" | "throw" = "respond";
  static terminated = 0;
  onmessage: ((event: MessageEvent<any>) => void) | null = null;
  onerror: (() => void) | null = null;
  onmessageerror: (() => void) | null = null;
  constructor(..._args: any[]) { if (FindReplaceWorker.mode === "throw") throw new Error("unavailable"); }
  terminate() { FindReplaceWorker.terminated += 1; }
  postMessage(request: any) {
    if (FindReplaceWorker.mode === "never") return;
    const matches: Array<{ from: number; to: number }> = [];
    let at = request.text.indexOf(request.query);
    while (request.query && at >= 0) { matches.push({ from: at, to: at + request.query.length }); at = request.text.indexOf(request.query, at + request.query.length); }
    const first = matches[0];
    const data = request.kind === "preview"
      ? { requestId: request.requestId, error: null, matches, proposedText: request.text.split(request.query).join(request.replacement), replacementCount: matches.length }
      : request.kind === "replaceCurrentOrNext" && first
        ? { requestId: request.requestId, error: null, matches, proposedText: `${request.replacement}${request.text.slice(first.to)}`, replacementCount: 1, selection: { from: 0, to: request.replacement.length }, index: 0, total: matches.length, wrapped: false }
        : { requestId: request.requestId, error: null, matches };
    queueMicrotask(() => this.onmessage?.({ data } as MessageEvent));
  }
}

let root: Root | null = null;
let host: HTMLDivElement | null = null;
afterEach(() => { if (root) act(() => root?.unmount()); root = null; host?.remove(); host = null; FindReplaceWorker.mode = "respond"; FindReplaceWorker.terminated = 0; vi.useRealTimers(); vi.unstubAllGlobals(); });

function input(host: HTMLElement, index: number): HTMLInputElement { return host.querySelectorAll("input")[index] as HTMLInputElement; }
function button(host: HTMLElement, label: string): HTMLButtonElement { return Array.from(host.querySelectorAll("button")).find((item) => item.textContent === label) as HTMLButtonElement; }
async function setInput(element: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
  await act(async () => { setter?.call(element, value); element.dispatchEvent(new Event("input", { bubbles: true })); });
}
async function setSelect(element: HTMLSelectElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")?.set;
  await act(async () => { setter?.call(element, value); element.dispatchEvent(new Event("change", { bubbles: true })); });
}

describe("MarkdownFindReplacePanel", () => {
  it("previews without writing, cancels unchanged, and confirms only the body edit", async () => {
    vi.stubGlobal("Worker", FindReplaceWorker);
    const value = "---\ntitle: needle\n---\nneedle needle";
    const onChange = vi.fn();
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    await act(async () => { root?.render(createElement(MarkdownFindReplacePanel, { value, selection: { from: value.length, to: value.length }, documentKey: "doc:one", onChange })); });
    await setInput(input(host, 0), "needle"); await setInput(input(host, 1), "done");
    await act(async () => { button(host!, "预览全部替换").click(); await Promise.resolve(); });
    expect(onChange).not.toHaveBeenCalled(); expect(host.textContent).toContain("确认全部替换"); expect(host.textContent).toContain("2 处");
    await act(async () => { button(host!, "取消").click(); });
    expect(onChange).not.toHaveBeenCalled();
    await act(async () => { button(host!, "预览全部替换").click(); await Promise.resolve(); });
    await act(async () => { button(host!, "确认替换").click(); });
    expect(onChange).toHaveBeenCalledWith("---\ntitle: needle\n---\ndone done", { from: 22, to: 22 }, {
      source: "已确认替换 {count} 处",
      parameters: { count: 2 },
    });
  });

  it("uses navigation to locate a match without treating it as a replacement", async () => {
    vi.stubGlobal("Worker", FindReplaceWorker);
    const onChange = vi.fn(); const onLocate = vi.fn();
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    await act(async () => { root?.render(createElement(MarkdownFindReplacePanel, { value: "needle and needle", selection: { from: 0, to: 0 }, documentKey: "doc:one", onChange, onLocate })); });
    await setInput(input(host, 0), "needle");
    await act(async () => { button(host!, "下一处").click(); await Promise.resolve(); });
    expect(onLocate).toHaveBeenCalledWith({ from: 0, to: 6 }, "needle and needle"); expect(onChange).not.toHaveBeenCalled();
  });

  it("reports a single replacement as a locale-neutral message descriptor", async () => {
    vi.stubGlobal("Worker", FindReplaceWorker);
    const onChange = vi.fn();
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    await act(async () => { root?.render(createElement(MarkdownFindReplacePanel, { value: "needle rest", selection: { from: 0, to: 0 }, onChange })); });
    await setInput(input(host, 0), "needle"); await setInput(input(host, 1), "done");
    await act(async () => { button(host!, "替换").click(); await Promise.resolve(); });
    expect(onChange).toHaveBeenCalledWith("done rest", { from: 0, to: 4 }, {
      source: "已替换 {count} 处",
      parameters: { count: 1 },
    });
  });

  it("fails closed when Worker construction fails and terminates a timed-out request", async () => {
    vi.stubGlobal("Worker", FindReplaceWorker); FindReplaceWorker.mode = "throw";
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    await act(async () => { root?.render(createElement(MarkdownFindReplacePanel, { value: "needle", selection: { from: 0, to: 0 }, onChange: vi.fn() })); });
    await setInput(input(host, 0), "needle"); await act(async () => { button(host!, "下一处").click(); await Promise.resolve(); });
    expect(host.textContent).toContain("工作线程不可用");
    FindReplaceWorker.mode = "never"; vi.useFakeTimers();
    await act(async () => { button(host!, "预览全部替换").click(); });
    await act(async () => { vi.advanceTimersByTime(1_500); await Promise.resolve(); });
    expect(FindReplaceWorker.terminated).toBeGreaterThan(0); expect(host.textContent).toContain("耗时过长");
  });

  it("cancels pending work when text, document identity, or read-only state changes", async () => {
    vi.stubGlobal("Worker", FindReplaceWorker); FindReplaceWorker.mode = "never";
    const onChange = vi.fn(); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    const render = async (value: string, documentKey: string, readOnly = false) => act(async () => { root?.render(createElement(MarkdownFindReplacePanel, { value, selection: { from: 0, to: 0 }, documentKey, readOnly, onChange })); });
    await render("needle", "one"); await setInput(input(host, 0), "needle"); await act(async () => { button(host!, "预览全部替换").click(); });
    await render("needle edited", "one"); expect(FindReplaceWorker.terminated).toBe(1);
    await act(async () => { button(host!, "预览全部替换").click(); }); await render("needle edited", "two"); expect(FindReplaceWorker.terminated).toBe(2);
    await act(async () => { button(host!, "预览全部替换").click(); }); await render("needle edited", "two", true); expect(FindReplaceWorker.terminated).toBe(3);
    expect(onChange).not.toHaveBeenCalled();
  });

  it("keeps a frozen selection after navigation and previews only that range", async () => {
    vi.stubGlobal("Worker", FindReplaceWorker);
    const value = "one needle two needle"; const first = value.indexOf("needle"); const onLocate = vi.fn();
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    await act(async () => { root?.render(createElement(MarkdownFindReplacePanel, { value, selection: { from: first, to: first + 6 }, documentKey: "one", onChange: vi.fn(), onLocate })); });
    await setInput(input(host, 0), "needle"); await setSelect(host.querySelector("select")!, "selection");
    await act(async () => { button(host!, "下一处").click(); await Promise.resolve(); }); expect(onLocate).toHaveBeenCalledWith({ from: first, to: first + 6 }, value);
    await act(async () => { button(host!, "预览全部替换").click(); await Promise.resolve(); });
    expect(host.textContent).toContain("确认全部替换"); expect(host.textContent).toContain("1 处");
  });
});
