import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { MarkdownFileEntry, RepositorySessionSnapshot } from "../contracts/repository";
import * as internalLinks from "../features/writing/markdownInternalLinks";
import type { MarkdownInternalLinkSuggestion } from "../features/writing/markdownInternalLinks";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { MarkdownInternalLinkPicker, type MarkdownInternalLinkPickerProps } from "./MarkdownInternalLinkPicker";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
let host: HTMLDivElement;
let root: Root;
const repository: RepositorySessionSnapshot = { sessionId: "s", rootPath: "/site", displayName: "Site", siteKind: "Hugo", contentRoot: "content", isGitRepository: false, warnings: [] };
const file = (relativePath: string, displayName = relativePath.split("/").pop()!): MarkdownFileEntry => ({ relativePath, displayName, directory: "content", byteSize: 1 });
function props(overrides: Partial<MarkdownInternalLinkPickerProps> = {}): MarkdownInternalLinkPickerProps {
  return { open: true, files: [file("content/guide.md", "Guide.md"), file("content/current.md", "Current.md")], currentPath: "content/current.md", repository, value: "See [[guide]] next", selection: { from: 11, to: 11 }, onClose: vi.fn(), onChange: vi.fn(), ...overrides };
}
beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  vi.spyOn(window, "requestAnimationFrame").mockImplementation(callback => { queueMicrotask(() => callback(0)); return 1; });
  vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => {});
});
afterEach(async () => {
  await act(async () => root.unmount()); host.remove(); vi.restoreAllMocks();
});
async function render(locale: UiLocale, picker: MarkdownInternalLinkPickerProps) {
  await act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(MarkdownInternalLinkPicker, picker) })));
}
function button(text: string) {
  const item = [...host.querySelectorAll<HTMLButtonElement>("button")].find(node => node.textContent === text || node.getAttribute("aria-label") === text);
  expect(item).toBeDefined(); return item!;
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

describe("internal-link picker localization", () => {
  it("translates controlled UI and ARIA while retaining query, focused node and raw suggestions through zh/en/zh", async () => {
    const picker = props({ value: "Body", selection: { from: 4, to: 4 }, files: [file("content/设置 {label}.md", "设置 {label}.md"), file("content/current.md")] });
    await render("zh-CN", picker);
    const input = host.querySelector("input")!;
    expect(input.placeholder).toBe("搜索标题或路径"); expect(input.getAttribute("aria-label")).toBe("搜索内部链接目标");
    expect(document.activeElement).toBe(input);
    await type(input, " 设置 {label} ");
    await render("en-US", picker);
    expect(host.querySelector("input")).toBe(input); expect(input.value).toBe(" 设置 {label} "); expect(document.activeElement).toBe(input);
    expect(input.placeholder).toBe("Search title or path"); expect(input.getAttribute("aria-label")).toBe("Search internal link targets");
    expect(host.querySelector('section[role="dialog"]')?.getAttribute("aria-labelledby")).toBe("markdown-internal-link-title");
    expect(host.querySelector("h2")?.textContent).toBe("Insert internal link");
    expect(host.textContent).toContain("Search Markdown documents in the current site; links use site routes.");
    expect(button("Close internal link picker")).toBeDefined(); expect(button("Insert link").disabled).toBe(false);
    expect(host.querySelector("h3")?.textContent).toBe("设置 {label}");
    expect(host.querySelector(".markdown-link-label")?.textContent).toBe("content/设置 {label}.md");
    expect(host.querySelector(".markdown-link-destination")?.textContent).toBe("/设置 {label}/");
    await render("zh-CN", picker);
    expect(host.querySelector("input")).toBe(input); expect(input.value).toBe(" 设置 {label} "); expect(document.activeElement).toBe(input);
    expect(host.querySelector("h2")?.textContent).toBe("插入内部链接"); expect(button("关闭内部链接选择器")).toBeDefined();
    expect(window.requestAnimationFrame).toHaveBeenCalledTimes(1); expect(picker.onClose).not.toHaveBeenCalled(); expect(picker.onChange).not.toHaveBeenCalled();
  });

  it.each(["zh-CN", "en-US"] as const)("reports %s success with exact paired-trigger Markdown and literal raw labels", async locale => {
    const raw = Object.freeze({ path: "content/raw {label}.md", label: "设置 {label} {other}]\\", url: "/中文 a/(b)%/{label}/" });
    vi.spyOn(internalLinks, "getInternalLinkSuggestions").mockReturnValue([raw]);
    const resolveSuggestion = vi.fn(async (suggestion: MarkdownInternalLinkSuggestion) => suggestion);
    const picker = props({ resolveSuggestion });
    await render(locale, picker); await click(locale === "en-US" ? "Insert link" : "插入链接");
    expect(resolveSuggestion).toHaveBeenCalledTimes(1); expect(resolveSuggestion.mock.calls[0][0]).toBe(raw);
    const label = "设置 {label} {other}\\]\\\\";
    expect(picker.onChange).toHaveBeenCalledExactlyOnceWith(`See [${label}](/%E4%B8%AD%E6%96%87%20a/%28b%29%25/%7Blabel%7D/) next`, { from: 5, to: 5 + label.length }, locale === "en-US" ? "Linked to “设置 {label} {other}]\\”" : "已链接到“设置 {label} {other}]\\”");
    expect(picker.onClose).toHaveBeenCalledTimes(1);
  });

  it("preserves a raw label exactly matching a controlled catalog key in English", async () => {
    const raw = Object.freeze({ path: "content/collision.md", label: "插入链接", url: "/collision/" });
    vi.spyOn(internalLinks, "getInternalLinkSuggestions").mockReturnValue([raw]);
    const picker = props(); await render("en-US", picker);
    expect(host.querySelector("h3")?.textContent).toBe("插入链接");
    expect(host.querySelector(".markdown-link-label")?.textContent).toBe("content/collision.md");
    expect(host.querySelector(".markdown-link-destination")?.textContent).toBe("/collision/");
    await click("Insert link");
    expect(picker.onChange).toHaveBeenCalledExactlyOnceWith("See [插入链接](/collision/) next", { from: 5, to: 9 }, "Linked to “插入链接”");
    expect(picker.onClose).toHaveBeenCalledTimes(1);
  });

  it("keeps one delayed resolver pending across locale changes and completes in the current locale", async () => {
    const pending = deferred<MarkdownInternalLinkSuggestion>();
    const resolveSuggestion = vi.fn((_suggestion: MarkdownInternalLinkSuggestion) => pending.promise);
    const picker = props({ resolveSuggestion });
    await render("zh-CN", picker); const input = host.querySelector("input")!; await click("插入链接"); input.focus();
    expect(button("正在读取…").disabled).toBe(true); expect(host.querySelector('[aria-live="polite"]')?.textContent).toBe("正在读取目标文章信息…");
    await render("en-US", picker);
    expect(button("Loading…").disabled).toBe(true); expect(host.querySelector('[aria-live="polite"]')?.textContent).toBe("Reading target article information…");
    await render("zh-CN", picker); await render("en-US", picker);
    expect(host.querySelector("input")).toBe(input); expect(input.value).toBe("guide"); expect(document.activeElement).toBe(input);
    expect(resolveSuggestion).toHaveBeenCalledTimes(1); expect(resolveSuggestion.mock.calls[0][0]).toEqual({ path: "content/guide.md", label: "Guide", url: "/guide/" });
    expect(picker.onChange).not.toHaveBeenCalled(); expect(picker.onClose).not.toHaveBeenCalled(); expect(window.requestAnimationFrame).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve({ path: "content/guide.md", label: "设置 {label}", url: "/resolved a/" }));
    expect(picker.onChange).toHaveBeenCalledExactlyOnceWith("See [设置 {label}](/resolved%20a/) next", { from: 5, to: 15 }, "Linked to “设置 {label}”");
    expect(picker.onClose).toHaveBeenCalledTimes(1); expect(resolveSuggestion).toHaveBeenCalledTimes(1);
  });

  it("retains direct selected-text insertion and translates the no-resolver success callback", async () => {
    const picker = props({ value: "before selected after", selection: { from: 7, to: 15 } });
    await render("en-US", picker); await click("Insert link");
    expect(picker.onChange).toHaveBeenCalledExactlyOnceWith("before [selected](/guide/) after", { from: 8, to: 16 }, "Linked to “Guide”");
    expect(picker.onClose).toHaveBeenCalledTimes(1);
  });

  it("preserves resolver failure fallback and renders its stored controlled status in either locale", async () => {
    const pending = deferred<MarkdownInternalLinkSuggestion>(); const resolveSuggestion = vi.fn(() => pending.promise);
    const picker = props({ resolveSuggestion });
    await render("zh-CN", picker); await click("插入链接"); await render("en-US", picker);
    await act(async () => pending.reject(new Error("设置 {label}")));
    expect(picker.onChange).toHaveBeenCalledExactlyOnceWith("See [Guide](/guide/) next", { from: 5, to: 10 }, "Linked to “Guide”");
    expect(picker.onClose).toHaveBeenCalledTimes(1);
    expect(host.querySelector('[aria-live="polite"]')?.textContent).toBe("Unable to read target article metadata; the file path was used to generate the link.");
    await render("zh-CN", picker);
    expect(host.querySelector('[aria-live="polite"]')?.textContent).toBe("无法读取目标文章元数据，已使用文件路径生成链接。");
    expect(resolveSuggestion).toHaveBeenCalledTimes(1); expect(picker.onChange).toHaveBeenCalledTimes(1); expect(picker.onClose).toHaveBeenCalledTimes(1);
  });

  it("translates invalid-link status without closing or emitting changes", async () => {
    vi.spyOn(internalLinks, "applyInternalLink").mockReturnValue(null);
    const picker = props(); await render("en-US", picker); await click("Insert link");
    expect(host.querySelector('[aria-live="polite"]')?.textContent).toBe("The link position changed. Reopen the picker.");
    expect(button("Insert link").disabled).toBe(false);
    await render("zh-CN", picker); expect(host.querySelector('[aria-live="polite"]')?.textContent).toBe("链接位置已变化，请重新打开选择器。");
    expect(picker.onClose).not.toHaveBeenCalled(); expect(picker.onChange).not.toHaveBeenCalled();
  });

  it("translates empty results and keeps disabled actions inert across locale changes", async () => {
    const resolveSuggestion = vi.fn(async (suggestion: MarkdownInternalLinkSuggestion) => suggestion);
    const picker = props({ disabled: true, resolveSuggestion }); await render("en-US", picker);
    expect(button("Insert link").disabled).toBe(true); await click("Insert link");
    await render("zh-CN", picker); expect(button("插入链接").disabled).toBe(true); await click("插入链接");
    const input = host.querySelector("input")!; await type(input, "no-match {label}");
    expect(host.querySelector(".markdown-library-empty")?.textContent).toBe("没有匹配的 Markdown 文档。");
    await render("en-US", picker); expect(host.querySelector(".markdown-library-empty")?.textContent).toBe("No matching Markdown documents.");
    expect(input.value).toBe("no-match {label}"); expect(resolveSuggestion).not.toHaveBeenCalled(); expect(picker.onClose).not.toHaveBeenCalled(); expect(picker.onChange).not.toHaveBeenCalled();
  });

  it("preserves close controls, Escape and scrim behavior in both locales", async () => {
    const picker = props(); await render("en-US", picker); await click("Close internal link picker");
    await render("zh-CN", picker); await click("关闭内部链接选择器");
    await act(async () => host.querySelector("h2")!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })));
    expect(picker.onClose).toHaveBeenCalledTimes(2);
    const escape = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    await act(async () => host.querySelector("input")!.dispatchEvent(escape)); expect(escape.defaultPrevented).toBe(true);
    await act(async () => host.querySelector(".markdown-library-scrim")!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })));
    expect(picker.onClose).toHaveBeenCalledTimes(4); expect(picker.onChange).not.toHaveBeenCalled();
  });

  it.each(["resolve", "reject"] as const)("ignores a stale delayed %s after close/reopen and resets pending state", async completion => {
    const trigger = document.createElement("button"); document.body.append(trigger); trigger.focus();
    try {
      const pending = deferred<MarkdownInternalLinkSuggestion>(); const resolveSuggestion = vi.fn(() => pending.promise);
      const picker = props({ resolveSuggestion }); await render("zh-CN", picker); await click("插入链接");
      await render("en-US", { ...picker, open: false }); expect(host.querySelector('[role="dialog"]')).toBeNull(); expect(document.activeElement).toBe(trigger);
      await render("en-US", picker); expect(button("Insert link").disabled).toBe(false); expect(host.querySelector('[aria-live="polite"]')?.textContent).toBe("");
      await act(async () => completion === "resolve" ? pending.resolve({ path: "stale.md", label: "设置 {label}", url: "/stale/" }) : pending.reject(new Error("stale")));
      expect(host.querySelector('[aria-live="polite"]')?.textContent).toBe(""); expect(button("Insert link").disabled).toBe(false);
      expect(resolveSuggestion).toHaveBeenCalledTimes(1); expect(picker.onClose).not.toHaveBeenCalled(); expect(picker.onChange).not.toHaveBeenCalled();
    } finally { trigger.remove(); }
  });
});
