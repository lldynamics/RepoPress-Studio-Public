import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { TextRange } from "../features/writing/markdownWriting";
import * as typography from "../features/writing/chineseTypography";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { ChineseTypographyButton, type ChineseTypographyButtonProps } from "./ChineseTypographyButton";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); });
function render(locale: UiLocale, props: ChineseTypographyButtonProps) {
  act(() => root.render(createElement(I18nProvider, { locale, children: createElement(ChineseTypographyButton, props) })));
}
const status = () => host.querySelector('[role="status"]')!.textContent;
const button = () => host.querySelector<HTMLButtonElement>("button")!;

describe("Chinese typography presentation", () => {
  it.each(["zh-CN", "en-US"] as const)("localizes %s controls and applies the same full-document edit", locale => {
    const onApply = vi.fn();
    render(locale, { value: "中文React", selection: { from: 2, to: 2 }, onApply, className: "custom" });
    expect(host.querySelector(".custom")).not.toBeNull();
    expect(button().textContent).toBe(locale === "en-US" ? "Chinese typography (Full document)" : "中文排版（全文）");
    expect(button().getAttribute("aria-label")).toBe(locale === "en-US" ? "Normalize Chinese/Western spacing, punctuation, and whitespace (Full document)" : "整理全文中文与西文间距、标点和空白");
    expect(button().title).toBe(button().getAttribute("aria-label"));
    act(() => button().click());
    expect(onApply).toHaveBeenCalledExactlyOnceWith({ text: "中文 React", selection: { from: 0, to: 0 } }, locale === "en-US" ? "Chinese typography normalized (Full document)" : "已整理全文中文排版");
    expect(status()).toBe(locale === "en-US" ? "Chinese typography normalized (Full document)" : "已整理全文中文排版");
  });

  it("retains action-time scope, node and focus across language and selection changes without applying again", () => {
    const value = "前😀中文React后Swift";
    const onApply = vi.fn();
    const props = { value, selection: { from: 3, to: 10 }, onApply };
    render("zh-CN", props); const node = button(); node.focus();
    act(() => node.click());
    expect(onApply).toHaveBeenCalledExactlyOnceWith({ text: "前😀中文 React后Swift", selection: { from: 3, to: 11 } }, "已整理选区中文排版");
    render("en-US", { ...props, selection: { from: 0, to: 0 } });
    expect(button()).toBe(node); expect(document.activeElement).toBe(node);
    expect(node.textContent).toBe("Chinese typography (Full document)");
    expect(status()).toBe("Chinese typography normalized (Selection)");
    render("zh-CN", { ...props, selection: { from: 0, to: 0 } });
    expect(button()).toBe(node); expect(document.activeElement).toBe(node);
    expect(status()).toBe("已整理选区中文排版"); expect(onApply).toHaveBeenCalledTimes(1);
  });

  it("relocalizes no-op feedback using its original scope without emitting an edit", () => {
    const onApply = vi.fn(); const props = { value: "中文 React", selection: { from: 0, to: 0 }, onApply };
    render("zh-CN", props); act(() => button().click()); expect(status()).toBe("全文无需调整");
    render("en-US", { ...props, selection: { from: 0, to: 2 } });
    expect(button().textContent).toBe("Chinese typography (Selection)");
    expect(status()).toBe("No typography changes needed (Full document)");
    expect(onApply).not.toHaveBeenCalled();
  });

  it("passes the original helper result and literal key-looking data to the callback", () => {
    const selection: TextRange = Object.freeze({ from: 1, to: 5 });
    const result = Object.freeze({ text: "设置 {scope} {{raw}}", selection: Object.freeze({ from: 2, to: 6 }) });
    const planner = vi.spyOn(typography, "planChineseTypography").mockReturnValue(result);
    const onApply = vi.fn(); render("en-US", { value: "原文 {scope}", selection, onApply });
    act(() => button().click());
    expect(planner).toHaveBeenCalledExactlyOnceWith("原文 {scope}", selection);
    expect(planner.mock.calls[0][1]).toBe(selection);
    expect(onApply.mock.calls[0][0]).toBe(result);
    expect(onApply).toHaveBeenCalledExactlyOnceWith(result, "Chinese typography normalized (Selection)");
    expect(result.text).toBe("设置 {scope} {{raw}}");
  });

  it("keeps disabled and empty actions inert in either language", () => {
    const planner = vi.spyOn(typography, "planChineseTypography"); const onApply = vi.fn();
    render("en-US", { value: "中文React", selection: { from: 0, to: 0 }, onApply, disabled: true });
    expect(button().disabled).toBe(true); act(() => button().click());
    render("zh-CN", { value: "", selection: { from: 0, to: 0 }, onApply });
    expect(button().disabled).toBe(true); act(() => button().click());
    expect(status()).toBe(""); expect(planner).not.toHaveBeenCalled(); expect(onApply).not.toHaveBeenCalled();
  });
});
