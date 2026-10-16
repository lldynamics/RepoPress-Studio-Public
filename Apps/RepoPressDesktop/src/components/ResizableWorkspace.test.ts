import { act, createElement, useEffect, useState, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WORKSPACE_LAYOUT_STORAGE_KEY } from "../features/workspace/workspaceLayout";
import { ResizableWorkspace } from "./ResizableWorkspace";

class ResizeObserverMock {
  static instances: ResizeObserverMock[] = [];
  readonly callback: ResizeObserverCallback;
  readonly observe = vi.fn();
  readonly disconnect = vi.fn();
  readonly unobserve = vi.fn();

  constructor(callback: ResizeObserverCallback) {
    this.callback = callback;
    ResizeObserverMock.instances.push(this);
  }

  emit(target: Element, width: number) {
    this.callback([{ target, contentRect: { width } as DOMRectReadOnly } as ResizeObserverEntry], this as unknown as ResizeObserver);
  }
}

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;

function content(label: string) {
  return createElement("div", { "data-testid": label }, label);
}

function renderWorkspace({ sidebar = content("sidebar"), preview = content("preview"), editor = content("editor"), inspector, inspectorVisible }: {
  sidebar?: ReactNode;
  preview?: ReactNode;
  editor?: ReactNode;
  inspector?: ReactNode;
  inspectorVisible?: boolean;
} = {}) {
  act(() => root.render(createElement(ResizableWorkspace, { sidebar, editor, preview, inspector, inspectorVisible })));
}

function workspace() {
  return host.querySelector<HTMLElement>("#workspace-content")!;
}

function resize(width: number) {
  act(() => ResizeObserverMock.instances[ResizeObserverMock.instances.length - 1]!.emit(workspace(), width));
}

function separator(label: string) {
  return host.querySelector<HTMLElement>(`[role="separator"][aria-label="${label}"]`)!;
}

function pointer(target: HTMLElement, type: string, init: { pointerId: number; clientX: number; button?: number }) {
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperties(event, {
    pointerId: { value: init.pointerId },
    clientX: { value: init.clientX },
    button: { value: init.button ?? 0 },
  });
  act(() => target.dispatchEvent(event));
}

let editorMounts = 0;
let inspectorMounts = 0;
function StatefulEditor() {
  const [edits, setEdits] = useState(0);
  useEffect(() => { editorMounts += 1; }, []);
  return createElement("button", { type: "button", "data-testid": "stateful-editor", onClick: () => setEdits((current) => current + 1) }, `编辑 ${edits}`);
}

function StatefulInspector() {
  const [checks, setChecks] = useState(0);
  useEffect(() => { inspectorMounts += 1; }, []);
  return createElement("button", { type: "button", "data-testid": "stateful-inspector", onClick: () => setChecks((current) => current + 1) }, `检查 ${checks}`);
}

describe("ResizableWorkspace", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

  beforeEach(() => {
    ResizeObserverMock.instances = [];
    vi.stubGlobal("ResizeObserver", ResizeObserverMock);
    window.localStorage.clear();
    editorMounts = 0;
    inspectorMounts = 0;
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
  });

  afterEach(() => {
    act(() => root.unmount());
    host.remove();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("keeps a stateful editor mounted while breakpoints and optional panels change", () => {
    renderWorkspace({ editor: createElement(StatefulEditor) });
    resize(1_200);
    const editorSlot = host.querySelector("#workspace-editor-slot");
    const editorButton = host.querySelector<HTMLButtonElement>("[data-testid='stateful-editor']")!;
    act(() => editorButton.click());
    expect(editorButton.textContent).toBe("编辑 1");
    expect(editorMounts).toBe(1);
    expect(workspace()).toMatchObject({ className: "workspace resizable-workspace" });
    expect(workspace().getAttribute("aria-label")).toBe("RepoPress 编辑工作区");
    expect(workspace().dataset.layout).toBe("wide");
    expect(host.querySelectorAll("[role='separator']")).toHaveLength(2);

    resize(800);
    expect(workspace().dataset.layout).toBe("compact");
    expect(host.querySelectorAll("[role='separator']")).toHaveLength(1);
    expect(host.querySelector("#workspace-editor-slot")).toBe(editorSlot);
    expect(host.querySelector("[data-testid='stateful-editor']")).toBe(editorButton);
    expect(editorButton.textContent).toBe("编辑 1");

    resize(480);
    expect(workspace().dataset.layout).toBe("narrow");
    expect(host.querySelectorAll("[role='separator']")).toHaveLength(0);
    expect(host.querySelector("#workspace-editor-slot")).toBe(editorSlot);
    expect(host.querySelector("[data-testid='stateful-editor']")).toBe(editorButton);

    renderWorkspace({ sidebar: null, preview: null, editor: createElement(StatefulEditor) });
    expect(host.querySelector("#workspace-editor-slot")).toBe(editorSlot);
    expect(host.querySelector("[data-testid='stateful-editor']")).toBe(editorButton);
    expect(editorButton.textContent).toBe("编辑 1");
    expect(editorMounts).toBe(1);
  });

  it("collapses narrow navigation into an expandable native disclosure without remounting the editor", async () => {
    renderWorkspace({
      sidebar: createElement("aside", { className: "sidebar", "data-testid": "repository-files" }, "文件 A"),
      editor: createElement(StatefulEditor),
    });
    resize(480);
    const editorButton = host.querySelector<HTMLButtonElement>("[data-testid='stateful-editor']")!;
    act(() => editorButton.click());
    const details = host.querySelector<HTMLDetailsElement>("#workspace-sidebar-slot > details")!;
    const summary = details.querySelector<HTMLElement>("summary")!;

    expect(details).not.toBeNull();
    expect(details.open).toBe(false);
    expect(summary.textContent).toBe("仓库文件");
    expect(workspace().style.getPropertyValue("--workspace-narrow-sidebar-height")).toBe("38px");
    expect(host.querySelector("[data-testid='repository-files']")).not.toBeNull();
    expect(editorButton.textContent).toBe("编辑 1");

    await act(async () => {
      summary.click();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(details.open).toBe(true);
    expect(workspace().style.getPropertyValue("--workspace-narrow-sidebar-height")).toBe("min(220px, 28vh)");
    expect(editorButton.textContent).toBe("编辑 1");
    expect(editorMounts).toBe(1);

    await act(async () => {
      summary.click();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(details.open).toBe(false);
    expect(workspace().style.getPropertyValue("--workspace-narrow-sidebar-height")).toBe("38px");
    resize(1_200);
    expect(host.querySelector("#workspace-sidebar-slot > details")).toBeNull();
    expect(host.querySelector("[data-testid='stateful-editor']")).toBe(editorButton);
    expect(editorButton.textContent).toBe("编辑 1");
    expect(editorMounts).toBe(1);
  });

  it("docks or lowers the inspector by container width and preserves both panel instances while hidden", () => {
    renderWorkspace({ editor: createElement(StatefulEditor), inspector: createElement(StatefulInspector) });
    resize(1_440);
    const editorButton = host.querySelector<HTMLButtonElement>("[data-testid='stateful-editor']")!;
    const inspectorButton = host.querySelector<HTMLButtonElement>("[data-testid='stateful-inspector']")!;
    act(() => { editorButton.click(); inspectorButton.click(); });
    expect(workspace().dataset.inspectorPosition).toBe("docked");
    const inspectorSlot = host.querySelector<HTMLElement>("#workspace-inspector-slot")!;
    expect(workspace().lastElementChild).toBe(inspectorSlot);
    expect(inspectorSlot.style.gridColumn).toBe("-2 / -1");
    expect(editorButton.textContent).toBe("编辑 1");
    expect(inspectorButton.textContent).toBe("检查 1");

    renderWorkspace({ editor: createElement(StatefulEditor), inspector: createElement(StatefulInspector), inspectorVisible: false });
    expect(workspace().dataset.inspectorPosition).toBe("hidden");
    expect(host.querySelector("#workspace-inspector-slot")?.hasAttribute("hidden")).toBe(true);
    expect(host.querySelector("[data-testid='stateful-editor']")).toBe(editorButton);
    expect(host.querySelector("[data-testid='stateful-inspector']")).toBe(inspectorButton);

    renderWorkspace({ editor: createElement(StatefulEditor), inspector: createElement(StatefulInspector), inspectorVisible: true });
    expect(workspace().dataset.inspectorPosition).toBe("docked");
    expect(host.querySelector("#workspace-inspector-slot")?.hasAttribute("hidden")).toBe(false);
    expect(editorButton.textContent).toBe("编辑 1");
    expect(inspectorButton.textContent).toBe("检查 1");

    resize(940);
    expect(workspace().dataset.layout).toBe("wide");
    expect(workspace().dataset.inspectorPosition).toBe("bottom");
    expect(host.querySelector("[data-testid='stateful-editor']")).toBe(editorButton);
    expect(host.querySelector("[data-testid='stateful-inspector']")).toBe(inspectorButton);

    resize(375);
    expect(workspace().dataset.layout).toBe("narrow");
    expect(workspace().dataset.inspectorPosition).toBe("bottom");
    expect(host.querySelector("[data-testid='stateful-editor']")).toBe(editorButton);
    expect(host.querySelector("[data-testid='stateful-inspector']")).toBe(inspectorButton);
    expect(editorMounts).toBe(1);
    expect(inspectorMounts).toBe(1);
  });

  it("resizes by keyboard, exposes live ARIA bounds, and persists numeric preferences", () => {
    renderWorkspace();
    resize(1_200);
    const handle = separator("调整文件导航宽度");
    expect(handle.getAttribute("aria-controls")).toBe("workspace-sidebar-slot");
    expect(handle.getAttribute("aria-valuenow")).toBe("250");

    act(() => handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true })));
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("260");
    expect(JSON.parse(window.localStorage.getItem(WORKSPACE_LAYOUT_STORAGE_KEY)!)).toEqual({
      sidebarWidth: 260,
      previewWidth: 340,
    });

    act(() => separator("调整预览宽度").dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true })));
    expect(separator("调整预览宽度").getAttribute("aria-valuenow")).toBe("350");
    expect(JSON.parse(window.localStorage.getItem(WORKSPACE_LAYOUT_STORAGE_KEY)!)).toEqual({
      sidebarWidth: 260,
      previewWidth: 350,
    });

    act(() => separator("调整文件导航宽度").dispatchEvent(new KeyboardEvent("keydown", { key: "End", bubbles: true, cancelable: true })));
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("360");
  });

  it("retains a hidden panel width and restores it without remounting the editor slot", () => {
    window.localStorage.setItem(WORKSPACE_LAYOUT_STORAGE_KEY, JSON.stringify({ sidebarWidth: 310, previewWidth: 430 }));
    renderWorkspace();
    resize(1_300);
    const editorSlot = host.querySelector("#workspace-editor-slot");
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("310");

    renderWorkspace({ sidebar: null });
    expect(host.querySelector("[aria-label='调整文件导航宽度']")).toBeNull();
    expect(host.querySelector("#workspace-sidebar-slot")?.hasAttribute("hidden")).toBe(true);
    expect(host.querySelector("#workspace-editor-slot")).toBe(editorSlot);

    renderWorkspace();
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("310");
    expect(separator("调整预览宽度").getAttribute("aria-valuenow")).toBe("430");
    expect(host.querySelector("#workspace-editor-slot")).toBe(editorSlot);
  });

  it("reverts a cancelled pointer resize, releases capture, and clears active state", () => {
    const captured = new Set<number>();
    renderWorkspace();
    resize(1_200);
    const handle = separator("调整文件导航宽度");
    const setPointerCapture = vi.fn((id: number) => { captured.add(id); });
    const releasePointerCapture = vi.fn((id: number) => { captured.delete(id); });
    Object.defineProperties(handle, {
      setPointerCapture: { configurable: true, value: setPointerCapture },
      releasePointerCapture: { configurable: true, value: releasePointerCapture },
      hasPointerCapture: { configurable: true, value: (id: number) => captured.has(id) },
    });

    pointer(handle, "pointerdown", { pointerId: 7, clientX: 250 });
    expect(setPointerCapture).toHaveBeenCalledWith(7);
    pointer(handle, "pointermove", { pointerId: 7, clientX: 300 });
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("300");
    expect(separator("调整文件导航宽度").classList.contains("is-resizing")).toBe(true);

    pointer(separator("调整文件导航宽度"), "pointercancel", { pointerId: 7, clientX: 300 });
    expect(releasePointerCapture).toHaveBeenCalledWith(7);
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("250");
    expect(separator("调整文件导航宽度").classList.contains("is-resizing")).toBe(false);
    expect(window.localStorage.getItem(WORKSPACE_LAYOUT_STORAGE_KEY)).toBeNull();
  });

  it("rolls back an unexpected capture loss and a handle removed during dragging", () => {
    const captured = new Set<number>();
    renderWorkspace();
    resize(1_200);
    const handle = separator("调整文件导航宽度");
    Object.defineProperties(handle, {
      setPointerCapture: { configurable: true, value: (id: number) => captured.add(id) },
      releasePointerCapture: { configurable: true, value: (id: number) => captured.delete(id) },
      hasPointerCapture: { configurable: true, value: (id: number) => captured.has(id) },
    });

    pointer(handle, "pointerdown", { pointerId: 8, clientX: 250 });
    pointer(handle, "pointermove", { pointerId: 8, clientX: 300 });
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("300");
    pointer(handle, "lostpointercapture", { pointerId: 8, clientX: 300 });
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("250");
    expect(separator("调整文件导航宽度").classList.contains("is-resizing")).toBe(false);

    captured.clear();
    pointer(handle, "pointerdown", { pointerId: 9, clientX: 250 });
    pointer(handle, "pointermove", { pointerId: 9, clientX: 300 });
    renderWorkspace({ sidebar: null });
    expect(host.querySelector("[aria-label='调整文件导航宽度']")).toBeNull();
    renderWorkspace();
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("250");

    const restoredHandle = separator("调整文件导航宽度");
    Object.defineProperties(restoredHandle, {
      setPointerCapture: { configurable: true, value: (id: number) => captured.add(id) },
      releasePointerCapture: { configurable: true, value: (id: number) => captured.delete(id) },
      hasPointerCapture: { configurable: true, value: (id: number) => captured.has(id) },
    });
    pointer(restoredHandle, "pointerdown", { pointerId: 10, clientX: 250 });
    pointer(restoredHandle, "pointermove", { pointerId: 10, clientX: 300 });
    resize(480);
    expect(host.querySelector("[aria-label='调整文件导航宽度']")).toBeNull();
    resize(1_200);
    expect(separator("调整文件导航宽度").getAttribute("aria-valuenow")).toBe("250");
    expect(window.localStorage.getItem(WORKSPACE_LAYOUT_STORAGE_KEY)).toBeNull();
  });
});
