import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import type { MarkdownDocumentExportPlan } from "../features/export/markdownDocumentExport";
import { MarkdownAdvancedEditingMenu } from "./MarkdownAdvancedEditingMenu";
import { MarkdownDocumentExportMenu } from "./MarkdownDocumentExportMenu";
import { MarkdownTableEditingMenu } from "./MarkdownTableEditingMenu";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); });
function render(locale: "zh-CN" | "en-US", node: React.ReactNode) { act(() => root.render(createElement(I18nProvider, { locale, children: node }))); }
async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }
function button(label: string) { const found = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label || item.getAttribute("aria-label") === label); expect(found).toBeDefined(); return found!; }
function click(label: string) { act(() => button(label).click()); }
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (reason?: unknown) => void; const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; }); return { promise, resolve, reject }; }

describe("editing menu localization lifecycle", () => {
  it("relocalizes an open advanced menu while preserving its details node", () => {
    const props = { value: "one\ntwo", selection: { from: 0, to: 3 }, onApply: vi.fn() };
    render("zh-CN", createElement(MarkdownAdvancedEditingMenu, props));
    const details = host.querySelector("details")!; details.setAttribute("open", "");
    render("en-US", createElement(MarkdownAdvancedEditingMenu, props));
    expect(host.querySelector("details")).toBe(details); expect((host.querySelector("details") as HTMLDetailsElement).open).toBe(true); expect(host.textContent).toContain("Line editing");
    render("zh-CN", createElement(MarkdownAdvancedEditingMenu, props));
    expect(host.querySelector("details")).toBe(details); expect((host.querySelector("details") as HTMLDetailsElement).open).toBe(true); expect(host.textContent).toContain("行编辑");
  });

  it("keeps advanced callback result exact and localizes completion status", () => {
    const onApply = vi.fn(); const props = { value: "one\ntwo", selection: { from: 0, to: 3 }, onApply };
    render("en-US", createElement(MarkdownAdvancedEditingMenu, props)); click("Move line down");
    expect(onApply).toHaveBeenCalledWith({ text: "two\none", selection: { from: 4, to: 7 } }, "Move line down complete");
  });

  it("keeps the details open when editing returns null and closes only after success", () => {
    const onApply = vi.fn();
    const props = { value: "---\ntitle: x\n---\nbody", selection: { from: 0, to: 3 }, onApply };
    render("zh-CN", createElement(MarkdownAdvancedEditingMenu, props));
    const details = host.querySelector<HTMLDetailsElement>("details")!; details.setAttribute("open", "");
    click("删除行");
    expect(details.open).toBe(true); expect(onApply).not.toHaveBeenCalled();
    render("zh-CN", createElement(MarkdownAdvancedEditingMenu, { value: "one\ntwo", selection: { from: 0, to: 3 }, onApply }));
    const successfulDetails = host.querySelector<HTMLDetailsElement>("details")!; successfulDetails.setAttribute("open", "");
    click("下移行"); expect(successfulDetails.open).toBe(false); expect(onApply).toHaveBeenCalledTimes(1);
  });

  it("keeps valid table context and disabled states while localizing table completion", () => {
    const value = "| A | B |\n| --- | --- |\n| 1 | 2 |"; const onApply = vi.fn(); const props = { value, selection: { from: value.indexOf("1"), to: value.indexOf("1") + 1 }, onApply };
    render("en-US", createElement(MarkdownTableEditingMenu, props));
    expect(button("Delete current row").disabled).toBe(false); click("Delete current row");
    expect(onApply).toHaveBeenCalledWith(expect.objectContaining({ text: expect.stringContaining("| A") }), "Delete current row complete");
    render("zh-CN", createElement(MarkdownTableEditingMenu, { ...props, disabled: true }));
    expect(button("删除当前行").disabled).toBe(true);
  });

  it("freezes one pending export plan across zh/en/zh and restores all buttons", async () => {
    const pending = deferred<void>(); const onSave = vi.fn((_plan: MarkdownDocumentExportPlan) => pending.promise); const onSuccess = vi.fn(); const props = { markdown: "# 原文", fileName: "原文.md", onSave, onSuccess };
    render("zh-CN", createElement(MarkdownDocumentExportMenu, props)); click("导出 Markdown…");
    const frozenPlan = onSave.mock.calls[0][0];
    render("en-US", createElement(MarkdownDocumentExportMenu, props)); render("zh-CN", createElement(MarkdownDocumentExportMenu, props));
    expect(onSave).toHaveBeenCalledTimes(1); expect(button("正在导出 Markdown…").disabled).toBe(true); expect(button("导出 HTML…").disabled).toBe(true);
    pending.resolve(); await settle(); expect(onSave).toHaveBeenCalledTimes(1); expect(onSuccess).toHaveBeenCalledWith(frozenPlan); expect(onSuccess.mock.calls[0][0]).toBe(frozenPlan); expect(button("导出 Markdown…").disabled).toBe(false);
  });

  it("keeps cancellation silent and does not call success", async () => {
    const onSuccess = vi.fn(); const onSave = vi.fn(async () => ({ status: "cancelled" as const }));
    render("en-US", createElement(MarkdownDocumentExportMenu, { markdown: "body", onSave, onSuccess })); click("Export HTML…"); await settle();
    expect(onSave).toHaveBeenCalledTimes(1); expect(onSuccess).not.toHaveBeenCalled(); expect(button("Export HTML…").disabled).toBe(false);
  });

  it("returns the original error object and restores busy controls", async () => {
    const error = { code: "raw", message: "原始错误 {设置}" }; const onError = vi.fn(); const onSave = vi.fn(async (_plan: MarkdownDocumentExportPlan) => { throw error; });
    render("zh-CN", createElement(MarkdownDocumentExportMenu, { markdown: "body", onSave, onError })); click("导出 HTML…"); const frozenPlan = onSave.mock.calls[0][0]; await settle();
    expect(onError.mock.calls[0][0]).toBe(error); expect(onError.mock.calls[0][1]).toMatchObject({ format: "html" }); expect(onError.mock.calls[0][1]).toBe(frozenPlan); expect(button("导出 HTML…").disabled).toBe(false);
  });
});
