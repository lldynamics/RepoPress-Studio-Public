import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import { BUILT_IN_MARKDOWN_SNIPPETS } from "../features/writing/markdownSnippets";
import { markdownSlashCommands, type SlashCommand } from "../features/writing/markdownPowerTools";
import { MarkdownSlashMenu } from "./MarkdownSlashMenu";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); });
function render(locale: "zh-CN" | "en-US", props: React.ComponentProps<typeof MarkdownSlashMenu>) { act(() => root.render(createElement(I18nProvider, { locale, children: createElement(MarkdownSlashMenu, props) }))); }
function key(target: Element, keyName: string) { act(() => target.dispatchEvent(new KeyboardEvent("keydown", { key: keyName, bubbles: true }))); }

describe("MarkdownSlashMenu localization", () => {
  it("presents every original core command in English while preserving command data", () => {
    const originals = markdownSlashCommands.map(command => ({ ...command, keywords: [...command.keywords] }));
    render("en-US", { query: "", open: true, commands: markdownSlashCommands, onSelect: vi.fn(), onClose: vi.fn() });
    expect([...host.querySelectorAll("strong")].map(node => node.textContent)).toEqual([
      "Content", "Heading 1", "Heading 2", "Heading 3", "Quote", "Bulleted list", "Numbered list",
      "Task list", "Code block", "Table", "Image placeholder", "Footnote", "Horizontal rule",
    ]);
    for (const node of host.querySelectorAll("button span")) expect(node.textContent).not.toMatch(/[\u4e00-\u9fff]/);
    expect(markdownSlashCommands).toEqual(originals);
  });

  it("localizes core commands while preserving active focus and original callbacks across locales", () => {
    const onSelect = vi.fn(); const onClose = vi.fn(); const commands = markdownSlashCommands.slice(0, 2);
    const props = { query: "", open: true, commands, onSelect, onClose, autoFocus: true };
    render("zh-CN", props);
    const first = host.querySelector<HTMLButtonElement>("#markdown-slash-command-paragraph")!;
    expect(first.textContent).toContain("正文"); expect(document.activeElement).toBe(first);
    key(first, "ArrowDown");
    const second = host.querySelector<HTMLButtonElement>("#markdown-slash-command-heading-1")!;
    expect(document.activeElement).toBe(second); expect(second.getAttribute("aria-selected")).toBe("true");
    render("en-US", props); expect(host.querySelector("#markdown-slash-command-heading-1")).toBe(second); expect(document.activeElement).toBe(second); expect(host.textContent).toContain("Heading 1");
    key(second, "Enter"); expect(onSelect).toHaveBeenCalledWith(commands[1]); expect(onSelect.mock.calls[0][0]).toBe(commands[1]);
    render("zh-CN", props); expect(host.textContent).toContain("一级标题"); expect(document.activeElement).toBe(second);
    key(second, "Escape"); expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("translates only explicitly marked, unmodified built-in snippet projections", () => {
    const builtin = BUILT_IN_MARKDOWN_SNIPPETS[0]; const secondBuiltin = BUILT_IN_MARKDOWN_SNIPPETS[1];
    const marked: SlashCommand = { id: `snippet:${builtin.id}`, label: builtin.label, description: builtin.description ?? "", keywords: [], template: builtin.template };
    const user: SlashCommand = { ...marked, id: "user-collision", label: builtin.label, description: builtin.description ?? "" };
    const modified: SlashCommand = { id: `snippet:${secondBuiltin.id}`, label: `${secondBuiltin.label} {user}`, description: secondBuiltin.description ?? "", keywords: [], template: secondBuiltin.template };
    const props = { query: "", open: true, commands: [marked, user, modified], onSelect: vi.fn(), onClose: vi.fn(), builtinSnippetCommandIds: [marked.id, modified.id] };
    render("en-US", props);
    const buttons = [...host.querySelectorAll<HTMLButtonElement>("button")];
    expect(buttons[0].textContent).toContain("Tutorial article");
    expect(buttons[1].textContent).toContain("教程文章");
    expect(buttons[2].textContent).toContain("评测文章 {user}");
    expect(marked.label).toBe("教程文章");
  });

  it("rejects provenance collisions and preserves each original command reference", () => {
    const builtin = BUILT_IN_MARKDOWN_SNIPPETS[0];
    const marked: SlashCommand = { id: `snippet:${builtin.id}`, label: builtin.label, description: builtin.description ?? "", keywords: [], template: builtin.template };
    const unmarkedExact: SlashCommand = { ...marked };
    const clonedCore: SlashCommand = { ...markdownSlashCommands[0] };
    const changedDescription: SlashCommand = { ...marked, description: `${marked.description} changed` };
    const onSelect = vi.fn();
    render("en-US", { query: "", open: true, commands: [unmarkedExact, clonedCore], onSelect, onClose: vi.fn(), builtinSnippetCommandIds: [] });
    const buttons = [...host.querySelectorAll<HTMLButtonElement>("button")];
    expect(buttons[0].textContent).toContain("教程文章");
    expect(buttons[1].textContent).toContain("正文");
    act(() => buttons[0].click()); act(() => buttons[1].click());
    render("en-US", { query: "", open: true, commands: [changedDescription], onSelect, onClose: vi.fn(), builtinSnippetCommandIds: [changedDescription.id] });
    const changedButton = host.querySelector<HTMLButtonElement>("button")!;
    expect(changedButton.textContent).toContain("教程文章");
    expect(changedButton.textContent).toContain("背景、步骤、验证和常见问题 changed");
    act(() => changedButton.click());
    expect(onSelect.mock.calls.map(([command]) => command)).toEqual([unmarkedExact, clonedCore, changedDescription]);
    expect(onSelect.mock.calls[0][0]).toBe(unmarkedExact);
    expect(onSelect.mock.calls[1][0]).toBe(clonedCore);
    expect(onSelect.mock.calls[2][0]).toBe(changedDescription);
  });

  it("localizes empty state and leaves closed or auto focus behavior intact", () => {
    const onClose = vi.fn(); const props = { query: "missing", open: true, commands: [], onSelect: vi.fn(), onClose, autoFocus: true };
    render("en-US", props); expect(host.getAttribute("role")).toBeNull(); expect(host.textContent).toContain("No matching commands");
    render("zh-CN", { ...props, open: false }); expect(host.textContent).toBe("");
  });
});
