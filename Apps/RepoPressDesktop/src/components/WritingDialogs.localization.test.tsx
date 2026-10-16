import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import type { MarkdownToolbarItemId } from "../features/writing/markdownToolbarExperience";
import { MarkdownToolbarCustomization } from "./MarkdownToolbarCustomization";
import { MarkdownShortcutHelp } from "./MarkdownShortcutHelp";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
let host: HTMLDivElement;
let root: Root;
let showModal: ReturnType<typeof vi.fn>;
let closeDialog: ReturnType<typeof vi.fn>;
const nativeDescriptors = new Map<string, PropertyDescriptor | undefined>();

beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  for (const key of ["showModal", "close"]) nativeDescriptors.set(key, Object.getOwnPropertyDescriptor(HTMLDialogElement.prototype, key));
  showModal = vi.fn(function (this: HTMLDialogElement) { this.setAttribute("open", ""); });
  closeDialog = vi.fn(function (this: HTMLDialogElement) { this.removeAttribute("open"); this.dispatchEvent(new Event("close")); });
  Object.defineProperty(HTMLDialogElement.prototype, "showModal", { configurable: true, value: showModal });
  Object.defineProperty(HTMLDialogElement.prototype, "close", { configurable: true, value: closeDialog });
  vi.spyOn(window, "requestAnimationFrame").mockImplementation(callback => { callback(0); return 1; });
});
afterEach(() => {
  act(() => root.unmount()); host.remove(); vi.restoreAllMocks();
  for (const [key, descriptor] of nativeDescriptors) {
    if (descriptor) Object.defineProperty(HTMLDialogElement.prototype, key, descriptor);
    else Reflect.deleteProperty(HTMLDialogElement.prototype, key);
  }
  nativeDescriptors.clear();
});
async function render(locale: UiLocale, child: React.ReactNode) {
  await act(async () => root.render(createElement(I18nProvider, { locale, children: child })));
}
function button(text: string) {
  const target = [...host.querySelectorAll<HTMLButtonElement>("button")].find(item => item.textContent === text || item.getAttribute("aria-label") === text);
  expect(target).toBeDefined(); return target!;
}
async function click(text: string) { await act(async () => button(text).click()); }
async function type(input: HTMLInputElement, value: string) {
  await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); });
}
function deferred<T>() {
  let resolve!: (value: T) => void; let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

describe("writing dialog localization lifecycle", () => {
  it("preserves the edited toolbar and focused node, then saves one exact draft while locale changes", async () => {
    const pending = deferred<void>();
    const onSave = vi.fn((_items: MarkdownToolbarItemId[]) => pending.promise); const onClose = vi.fn();
    const props = { open: true, itemIds: ["bold", "italic"] as MarkdownToolbarItemId[], onSave, onClose };
    await render("zh-CN", createElement(MarkdownToolbarCustomization, props));
    await click("下移 粗体");
    const italic = host.querySelector<HTMLInputElement>('input[type="checkbox"]')!;
    expect(italic.closest("label")?.textContent).toBe("斜体");
    await act(async () => italic.click()); italic.focus();
    await render("en-US", createElement(MarkdownToolbarCustomization, props));
    expect(host.contains(italic)).toBe(true); expect(italic.closest("label")?.textContent).toBe("Italic");
    expect(document.activeElement).toBe(italic); expect(italic.checked).toBe(false);
    expect(showModal).toHaveBeenCalledTimes(1); expect(closeDialog).not.toHaveBeenCalled();
    await click("Save");
    const captured = onSave.mock.calls[0][0]; expect(captured).toEqual(["bold"]);
    await render("zh-CN", createElement(MarkdownToolbarCustomization, props));
    await render("en-US", createElement(MarkdownToolbarCustomization, props));
    expect(button("Saving…").disabled).toBe(true); expect(button("Cancel").disabled).toBe(true);
    await click("Cancel"); expect(onClose).not.toHaveBeenCalled();
    expect(onSave).toHaveBeenCalledTimes(1); expect(onSave.mock.calls[0][0]).toBe(captured);
    await act(async () => pending.resolve());
    expect(onClose).toHaveBeenCalledTimes(1); expect(onSave).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["controlled fallback", "transport failure", "Unable to save the toolbar configuration. Try again."],
    ["raw dictionary collision", new Error("保存工具栏配置失败，请重试。"), "保存工具栏配置失败，请重试。"],
  ])("renders %s in its proper provenance after a delayed save", async (_name, reason, expected) => {
    const pending = deferred<void>(); const onClose = vi.fn();
    const onSave = vi.fn((_items: MarkdownToolbarItemId[]) => pending.promise);
    const props = { open: true, itemIds: [] as MarkdownToolbarItemId[], onSave, onClose };
    await render("zh-CN", createElement(MarkdownToolbarCustomization, props)); await click("保存");
    await render("en-US", createElement(MarkdownToolbarCustomization, props));
    await act(async () => pending.reject(reason));
    expect(host.querySelector('[role="alert"]')?.textContent).toBe(expected);
    expect(button("Save").disabled).toBe(false); expect(onClose).not.toHaveBeenCalled();
    await render("zh-CN", createElement(MarkdownToolbarCustomization, props));
    expect(host.querySelector('[role="alert"]')?.textContent).toBe("保存工具栏配置失败，请重试。");
    await render("en-US", createElement(MarkdownToolbarCustomization, props));
    expect(host.querySelector('[role="alert"]')?.textContent).toBe(expected); expect(onSave).toHaveBeenCalledTimes(1);
  });

  it("preserves shortcut search and focus across locale switches without reopening the dialog", async () => {
    const node = createElement(MarkdownShortcutHelp);
    await render("zh-CN", node); await click("快捷键");
    const input = host.querySelector("input")!; expect(document.activeElement).toBe(input);
    await type(input, "ｔａｂ");
    const keys = [...host.querySelectorAll("kbd")].map(item => item.textContent);
    expect(keys).toEqual(["Tab", "Shift Tab"]);
    await render("en-US", node);
    expect(host.querySelector("input")).toBe(input); expect(input.value).toBe("ｔａｂ");
    expect(document.activeElement).toBe(input); expect(host.textContent).toContain("Next table cell");
    await render("zh-CN", node); await render("en-US", node);
    expect([...host.querySelectorAll("kbd")].map(item => item.textContent)).toEqual(keys);
    expect(showModal).toHaveBeenCalledTimes(1); expect(closeDialog).not.toHaveBeenCalled();
    await type(input, "no-matching-command"); expect(host.textContent).toContain("No matching shortcuts.");
    await render("zh-CN", node); expect(host.textContent).toContain("没有匹配的快捷键。");
    const cancel = new Event("cancel", { cancelable: true });
    await act(async () => host.querySelector("dialog")!.dispatchEvent(cancel));
    expect(cancel.defaultPrevented).toBe(true); expect(document.activeElement).toBe(button("快捷键"));
    await click("快捷键"); expect(input.value).toBe(""); expect(showModal).toHaveBeenCalledTimes(2);
  });

  it("keeps a disabled shortcut trigger inert in either locale", async () => {
    await render("en-US", createElement(MarkdownShortcutHelp, { disabled: true }));
    await click("Shortcuts"); expect(showModal).not.toHaveBeenCalled();
    await render("zh-CN", createElement(MarkdownShortcutHelp, { disabled: true }));
    expect(button("快捷键").disabled).toBe(true); expect(host.querySelector("dialog")?.open).toBe(false);
  });
});
