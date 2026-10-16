import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import { MarkdownCursorWorkflowControls } from "./MarkdownCursorWorkflowControls";

describe("localized cursor fence status", () => {
  let host: HTMLDivElement | undefined;
  let root: ReturnType<typeof createRoot> | undefined;
  afterEach(() => { act(() => root?.unmount()); host?.remove(); });
  it("localizes closed and unclosed fence status without changing navigation ranges", () => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    const value = "```ts\n原始代码\n```";
    const onSelect = vi.fn();
    const render = (text: string) => act(() => root!.render(createElement(I18nProvider, { locale: "en-US", children: createElement(MarkdownCursorWorkflowControls, { value: text, selection: { from: 7, to: 7 }, onSelect }) })));
    render(value);
    expect(host.textContent).toContain("Code fence: lines 1–3");
    const jump = [...host.querySelectorAll("button")].find((button) => button.textContent === "Jump to end")!;
    act(() => jump.click());
    expect(onSelect.mock.calls[0][0]).toEqual({ from: value.lastIndexOf("```"), to: value.length });
    render("```ts\n原始代码");
    expect(host.textContent).toContain("Code fence: line 1 (unclosed)");
    expect(host.textContent).not.toContain("Jump to end");
  });
});
