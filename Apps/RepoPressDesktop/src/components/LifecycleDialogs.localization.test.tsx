import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import type { EditorExitState } from "../features/workspace/editorExit";
import type { UiMessage } from "../i18n/uiMessage";
import { DraftLifecycleDialog } from "./DraftLifecycleDialog";
import { EditorExitDialog } from "./EditorExitDialog";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let host: HTMLDivElement;
let root: Root;
const originalDialogShowModal = Object.getOwnPropertyDescriptor(HTMLDialogElement.prototype, "showModal");
const originalDialogClose = Object.getOwnPropertyDescriptor(HTMLDialogElement.prototype, "close");
beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => { callback(0); return 1; });
  vi.stubGlobal("cancelAnimationFrame", vi.fn());
});
afterEach(() => {
  act(() => root.unmount()); host.remove(); vi.unstubAllGlobals();
  if (originalDialogShowModal) Object.defineProperty(HTMLDialogElement.prototype, "showModal", originalDialogShowModal); else Reflect.deleteProperty(HTMLDialogElement.prototype, "showModal");
  if (originalDialogClose) Object.defineProperty(HTMLDialogElement.prototype, "close", originalDialogClose); else Reflect.deleteProperty(HTMLDialogElement.prototype, "close");
});
function render(node: React.ReactNode, locale: "zh-CN" | "en-US") { act(() => root.render(createElement(I18nProvider, { locale, children: node }))); }
function button(text: string) { return [...host.querySelectorAll<HTMLButtonElement>("button")].find(item => item.textContent === text)!; }

describe("lifecycle dialog localization", () => {
  it("round-trips locale without resetting a dirty path or input focus", () => {
    const onSubmit = vi.fn(); const onClose = vi.fn();
    const props = { open: true, mode: "rename" as const, currentPath: "posts/original.md", onSubmit, onClose };
    render(createElement(DraftLifecycleDialog, props), "zh-CN");
    const input = host.querySelector<HTMLInputElement>("input")!; act(() => { const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!; setValue.call(input, " posts/changed.md "); input.dispatchEvent(new Event("input", { bubbles: true })); });
    input.focus(); render(createElement(DraftLifecycleDialog, props), "en-US"); render(createElement(DraftLifecycleDialog, props), "zh-CN");
    expect(host.querySelector("input")).toBe(input); expect(input.value).toBe(" posts/changed.md "); expect(document.activeElement).toBe(input);
    act(() => button("确认重命名").click()); expect(onSubmit).toHaveBeenCalledWith("posts/changed.md");
  });

  it("trims create paths, submits delete as undefined once, and freezes busy controls", () => {
    const onSubmit = vi.fn(); const onClose = vi.fn();
    render(createElement(DraftLifecycleDialog, { open: true, mode: "create", suggestedPath: "draft.md", onSubmit, onClose }), "zh-CN");
    const input = host.querySelector<HTMLInputElement>("input")!; act(() => { const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!; setValue.call(input, "  new.md  "); input.dispatchEvent(new Event("input", { bubbles: true })); });
    act(() => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }))); act(() => button("创建并打开").click());
    expect(onSubmit).toHaveBeenCalledTimes(2); expect(onSubmit).toHaveBeenNthCalledWith(1, "new.md");
    render(createElement(DraftLifecycleDialog, { open: true, mode: "delete", currentPath: "old.md", busy: true, onSubmit, onClose }), "en-US");
    expect(button("Cancel").disabled).toBe(true); expect(button("Processing…").disabled).toBe(true);
    act(() => window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }))); expect(onClose).not.toHaveBeenCalled();
    render(createElement(DraftLifecycleDialog, { open: true, mode: "delete", currentPath: "old{设置}.md", error: "删除文章", onSubmit, onClose }), "en-US");
    expect(host.textContent).toContain("删除文章"); expect(host.querySelector(".draft-delete-target code")?.textContent).toBe("old{设置}.md");
    act(() => button("Delete article").click());
    expect(onSubmit).toHaveBeenCalledTimes(3); expect(onSubmit).toHaveBeenLastCalledWith(undefined);
  });

  it("localizes editor exit metadata while preserving raw export paths and pending buttons", () => {
    const showModal = vi.fn(); const close = vi.fn();
    Object.defineProperty(HTMLDialogElement.prototype, "showModal", { configurable: true, value: showModal });
    Object.defineProperty(HTMLDialogElement.prototype, "close", { configurable: true, value: close });
    const onCancel = vi.fn(); const onFinish = vi.fn();
    const errorPresentation: UiMessage = { source: "自动恢复已关闭。请导出当前文章恢复包，或返回编辑并保存文章。" };
    const rawExportPath = "/tmp/导出{设置}.zip";
    const state = { open: true, busy: false, error: "controller-private-error", errorPresentation, exportPath: rawExportPath, snapshot: { draft: {} as never, dirty: true, recoveryEnabled: true } } as EditorExitState & { errorPresentation?: UiMessage };
    render(createElement(EditorExitDialog, { state, onCancel, onFinish }), "en-US");
    expect(host.textContent).toContain("Automatic recovery is disabled"); expect(host.textContent).toContain(rawExportPath); expect(host.querySelector(".editor-exit-dialog code")?.textContent).toBe(rawExportPath);
    expect(button("Return to editing").disabled).toBe(false); expect(button("Export recovery package and exit").disabled).toBe(false); expect(button("Save recovery draft and exit").disabled).toBe(false);
    render(createElement(EditorExitDialog, { state, onCancel, onFinish }), "zh-CN"); expect(host.textContent).toContain("自动恢复已关闭。请导出当前文章恢复包"); expect(host.querySelector(".editor-exit-dialog code")?.textContent).toBe(rawExportPath);
    expect(showModal).toHaveBeenCalledTimes(1); expect(close).not.toHaveBeenCalled();
    act(() => button("返回编辑").click()); act(() => button("导出恢复包并退出").click()); act(() => button("保存恢复草稿并退出").click());
    expect(onCancel).toHaveBeenCalledTimes(1); expect(onFinish).toHaveBeenCalledTimes(2); expect(onFinish).toHaveBeenNthCalledWith(1, "export"); expect(onFinish).toHaveBeenNthCalledWith(2, "recovery");
    vi.restoreAllMocks();
  });

  it("keeps a raw controller error literal when no presentation metadata exists", () => {
    const state = { open: true, busy: false, error: "自动恢复已关闭。请导出当前文章恢复包，或返回编辑并保存文章。", exportPath: null, snapshot: null } as EditorExitState;
    render(createElement(EditorExitDialog, { state, onCancel: vi.fn(), onFinish: vi.fn() }), "en-US");
    expect(host.querySelector('[role="alert"]')?.textContent).toBe(state.error);
  });
});
