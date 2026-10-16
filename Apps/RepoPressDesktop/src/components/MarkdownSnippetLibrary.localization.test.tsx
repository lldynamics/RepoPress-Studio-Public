import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import { writingBuiltinSnippetMessages } from "../i18n/writingBuiltinSnippetMessages";
import { availableMarkdownSnippets, BUILT_IN_MARKDOWN_SNIPPETS, insertMarkdownSnippet, type MarkdownSnippet } from "../features/writing/markdownSnippets";
import { MARKDOWN_CUSTOM_SNIPPETS_STORAGE_KEY, MarkdownSnippetLibrary, type MarkdownSnippetLibraryProps } from "./MarkdownSnippetLibrary";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
let host: HTMLDivElement;
let root: Root;
let props: MarkdownSnippetLibraryProps;
let scopeNumber = 0;
beforeEach(() => {
  window.localStorage.clear();
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  props = { open: true, scope: `snippet-localization-${++scopeNumber}`, context: { title: "原始 {title}", slug: "raw-slug", date: "2026-10-05" }, value: "前文选中文字后文", selection: { from: 2, to: 7 }, onClose: vi.fn(), onChange: vi.fn(), onCustomSnippetsChange: vi.fn() };
  // Flush the existing scheduled initial focus before testing language-only rerenders.
  vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => { queueMicrotask(() => callback(0)); return 1; });
});
afterEach(async () => { await act(async () => root.unmount()); host.remove(); vi.restoreAllMocks(); });
async function render(locale: "zh-CN" | "en-US") { await act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(MarkdownSnippetLibrary, props) }))); }
function button(label: string, parent: ParentNode = host) {
  const found = [...parent.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === label);
  if (!found) throw new Error(`Missing button ${label}`);
  return found;
}
async function click(label: string, parent: ParentNode = host) { await act(async () => button(label, parent).click()); }
async function setInput(element: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, value: string) {
  const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : element instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
  await act(async () => { Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(element, value); element.dispatchEvent(new Event(element instanceof HTMLSelectElement ? "change" : "input", { bubbles: true })); });
}
function form() { return host.querySelector<HTMLDivElement>(".markdown-library-form")!; }
function rows() { return [...host.querySelectorAll<HTMLElement>(".markdown-library-item")]; }
function lastRow() { const items = rows(); return items[items.length - 1]; }
function stored(snippets: MarkdownSnippet[]) { window.localStorage.setItem(MARKDOWN_CUSTOM_SNIPPETS_STORAGE_KEY, JSON.stringify({ [props.scope]: snippets, otherSite: [{ literal: "不改动" }] })); }
function custom(overrides: Partial<MarkdownSnippet> = {}): MarkdownSnippet { return { id: "user-raw", label: "教程文章", description: "背景、步骤、验证和常见问题", shortcut: "user-raw", kind: "snippet", template: "# {{title}}\n原文 {{slug}} {{date}} {name}", selectionToken: "原文", ...overrides }; }

describe("MarkdownSnippetLibrary localization", () => {
  it("localizes every built-in presentation while inserting the original Markdown and selection in both locales", async () => {
    const originals = BUILT_IN_MARKDOWN_SNIPPETS.map((snippet) => ({ ...snippet }));
    for (const locale of ["en-US", "zh-CN"] as const) {
      await render(locale);
      expect(host.querySelector("[role=dialog]")?.getAttribute("aria-modal")).toBe("true");
      expect(host.querySelector(".markdown-library-search")?.getAttribute("aria-label")).toBe(locale === "en-US" ? "Search Markdown snippets" : "搜索 Markdown 片段");
      for (const [index, snippet] of BUILT_IN_MARKDOWN_SNIPPETS.entries()) {
        const row = rows()[index];
        const name = locale === "en-US" ? writingBuiltinSnippetMessages[snippet.label] : snippet.label;
        expect(row.querySelector("h3")?.firstChild?.textContent).toBe(name);
        expect(row.querySelector("p")?.textContent).toBe(locale === "en-US" ? writingBuiltinSnippetMessages[snippet.description!] : snippet.description);
        expect(row.querySelector("code")?.textContent).toBe(originals[index].template);
        await click(locale === "en-US" ? "Insert" : "插入", row);
        const expected = insertMarkdownSnippet(props.value, props.selection, originals[index], props.context);
        expect(props.onChange).toHaveBeenLastCalledWith(expected.text, expected.selection, locale === "en-US" ? `Inserted “${name}”` : `已插入“${name}”`);
      }
    }
    expect(BUILT_IN_MARKDOWN_SNIPPETS).toEqual(originals);
    expect(props.onClose).toHaveBeenCalledTimes(originals.length * 2);
  });

  it("keeps custom dictionary collisions and braces literal in rows, forms, and insertion envelopes", async () => {
    const snippets = [custom(), custom({ id: "user-token", shortcut: "user-token", label: "标题 {name} {{title}}", description: "设置 {shortcut} {{slug}}" })];
    stored(snippets); await render("en-US");
    for (const [index, snippet] of snippets.entries()) {
      const row = rows()[BUILT_IN_MARKDOWN_SNIPPETS.length + index];
      expect(row.querySelector("h3")?.firstChild?.textContent).toBe(snippet.label);
      expect(row.querySelector("p")?.textContent).toBe(snippet.description);
      expect(row.querySelector("code")?.textContent).toBe(snippet.template);
      await click("Edit", row);
      expect(form().querySelector("input")?.value).toBe(snippet.label);
      expect(form().querySelector("textarea")?.value).toBe(snippet.template);
      await click("Insert", row);
      const expected = insertMarkdownSnippet(props.value, props.selection, snippet, props.context);
      expect(props.onChange).toHaveBeenLastCalledWith(expected.text, expected.selection, `Inserted “${snippet.label}”`);
    }
  });

  it("preserves raw search, category, form values, selection and focus across zh/en/zh without reads, writes or callbacks", async () => {
    stored([custom()]); await render("zh-CN");
    const query = host.querySelector<HTMLInputElement>(".markdown-library-search")!;
    await setInput(query, "背景"); await click("模板"); await click("新建自定义片段");
    const fields = [...form().querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>("input, textarea, select")];
    const draftValues = ["未保存 {name}", "draft-shortcut", "原始说明", "articleTemplate", "# {{title}}\n草稿 {{slug}} {{date}}"];
    for (const [index, value] of draftValues.entries()) await setInput(fields[index], value);
    const textarea = form().querySelector("textarea")!;
    textarea.focus(); textarea.setSelectionRange(3, 12);
    const focus = vi.spyOn(HTMLElement.prototype, "focus");
    const reads = vi.spyOn(Storage.prototype, "getItem"); const writes = vi.spyOn(Storage.prototype, "setItem");
    const callbackCount = vi.mocked(props.onCustomSnippetsChange!).mock.calls.length;
    for (const locale of ["en-US", "zh-CN"] as const) {
      await render(locale);
      expect(host.querySelector(".markdown-library-search")).toBe(query); expect(query.value).toBe("背景");
      expect(rows()).toHaveLength(1); expect(rows()[0].querySelector("code")?.textContent).toBe(BUILT_IN_MARKDOWN_SNIPPETS[0].template);
      expect(host.querySelectorAll(".markdown-library-filter button")[1].getAttribute("aria-pressed")).toBe("true");
      expect([...form().querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>("input, textarea, select")].map((field) => field.value)).toEqual(draftValues);
      expect(form().querySelector("textarea")).toBe(textarea); expect(document.activeElement).toBe(textarea);
      expect([textarea.selectionStart, textarea.selectionEnd]).toEqual([3, 12]);
      expect(textarea.placeholder).toBe(locale === "en-US" ? "You can use {{title}}、{{slug}}、{{date}}" : "可使用 {{title}}、{{slug}}、{{date}}");
    }
    expect(focus).not.toHaveBeenCalled(); expect(reads).not.toHaveBeenCalled(); expect(writes).not.toHaveBeenCalled();
    expect(props.onCustomSnippetsChange).toHaveBeenCalledTimes(callbackCount); expect(props.onChange).not.toHaveBeenCalled(); expect(props.onClose).not.toHaveBeenCalled();
    // English presentation is not added to the helper's raw search semantics.
    await setInput(query, "Tutorial article"); expect(rows()).toHaveLength(0);
  });

  it("saves and deletes exact raw payloads only after an explicit localized confirmation", async () => {
    const snippet = custom({ label: "标题 {name} {{title}}", description: "设置 {shortcut}" });
    stored([snippet]); await render("en-US");
    const writes = vi.spyOn(Storage.prototype, "setItem"); const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    const row = lastRow()!; await click("Edit", row);
    await setInput(form().querySelector("input")!, "教程文章 {name} {{title}}");
    // Existing edit behavior persists form fields only; selectionToken is not a form field.
    const expected = { id: snippet.id, label: "教程文章 {name} {{title}}", description: snippet.description, shortcut: snippet.shortcut, kind: snippet.kind, template: snippet.template };
    await click("Save to this site");
    expect(props.onCustomSnippetsChange).toHaveBeenLastCalledWith([expected]);
    expect(JSON.parse(writes.mock.calls[0][1])).toEqual({ [props.scope]: [expected], otherSite: [{ literal: "不改动" }] });
    expect(host.querySelector(".markdown-library-status")?.textContent).toBe("Custom snippet saved to this site.");
    await render("zh-CN"); expect(host.querySelector(".markdown-library-status")?.textContent).toBe("自定义片段已保存到此站点。");
    await click("删除", lastRow()!);
    expect(confirm).toHaveBeenLastCalledWith(`删除自定义片段“${expected.label}”？`); expect(writes).toHaveBeenCalledTimes(1);
    confirm.mockReturnValue(true); await render("en-US"); await click("Delete", lastRow()!);
    expect(confirm).toHaveBeenLastCalledWith(`Delete custom snippet “${expected.label}”?`);
    expect(props.onCustomSnippetsChange).toHaveBeenLastCalledWith([]); expect(writes).toHaveBeenCalledTimes(2);
    expect(JSON.parse(writes.mock.calls[1][1])).toEqual({ [props.scope]: [], otherSite: [{ literal: "不改动" }] });
    expect(host.querySelector(".markdown-library-status")?.textContent).toBe("Custom snippet deleted.");
  });

  it.each(["save", "delete"] as const)("rolls back a failed %s and translates its controlled status without retrying", async (operation) => {
    const snippet = custom(); stored([snippet]); await render("zh-CN");
    const callbackCount = vi.mocked(props.onCustomSnippetsChange!).mock.calls.length;
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
    const writes = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("标题 {name}"); });
    if (operation === "save") { await click("编辑", lastRow()!); await setInput(form().querySelector("input")!, "改名 {name}"); await click("保存到此站点"); }
    else await click("删除", lastRow()!);
    const source = operation === "save" ? "本地存储不可用，片段未保存。" : "本地存储不可用，片段未删除。";
    expect(host.querySelector(".markdown-library-status")?.textContent).toBe(source);
    expect(availableMarkdownSnippets(props.scope)[BUILT_IN_MARKDOWN_SNIPPETS.length]).toEqual(snippet);
    expect(lastRow()?.querySelector("h3")?.firstChild?.textContent).toBe(snippet.label);
    await render("en-US");
    expect(host.querySelector(".markdown-library-status")?.textContent).toBe(operation === "save" ? "Local storage is unavailable. The snippet was not saved." : "Local storage is unavailable. The snippet was not deleted.");
    await render("zh-CN"); expect(host.querySelector(".markdown-library-status")?.textContent).toBe(source);
    expect(writes).toHaveBeenCalledTimes(1); expect(confirm).toHaveBeenCalledTimes(operation === "delete" ? 1 : 0);
    expect(props.onCustomSnippetsChange).toHaveBeenCalledTimes(callbackCount); expect(props.onChange).not.toHaveBeenCalled();
    if (operation === "save") expect(form().querySelector("input")?.value).toBe("改名 {name}");
  });

  it("keeps validation status reactive to locale without submitting again", async () => {
    await render("zh-CN"); await click("新建自定义片段"); await click("保存到此站点");
    const writes = vi.spyOn(Storage.prototype, "setItem");
    expect(host.querySelector(".markdown-library-status")?.textContent).toBe("请填写片段名称和 Markdown 内容。");
    await render("en-US"); expect(host.querySelector(".markdown-library-status")?.textContent).toBe("Enter a snippet name and Markdown content.");
    await render("zh-CN"); expect(host.querySelector(".markdown-library-status")?.textContent).toBe("请填写片段名称和 Markdown 内容。");
    expect(writes).not.toHaveBeenCalled(); expect(form()).toBeTruthy();
  });

  it("preserves disabled insertion and close actions across language changes", async () => {
    props.disabled = true; await render("zh-CN"); await render("en-US");
    expect(button("Insert", rows()[0]).disabled).toBe(true); await click("Insert", rows()[0]); expect(props.onChange).not.toHaveBeenCalled();
    await act(async () => host.querySelector("[role=dialog]")!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    expect(props.onClose).toHaveBeenCalledTimes(1);
    props.open = false; await render("en-US"); expect(host.textContent).toBe("");
  });
});
