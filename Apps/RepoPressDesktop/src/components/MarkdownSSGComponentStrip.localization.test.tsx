import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import type { MarkdownSSGComponentKind, MarkdownSSGComponentOccurrence } from "../features/writing/markdownSSGComponents";
import { MarkdownSSGComponentStrip } from "./MarkdownSSGComponentStrip";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let host: HTMLDivElement;
let root: Root;

beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); });

const kinds: MarkdownSSGComponentKind[] = ["callout", "lead", "youtube", "bilibili", "githubCard", "figure", "custom"];
function occurrence(index: number, kind: MarkdownSSGComponentKind = kinds[index % kinds.length]): MarkdownSSGComponentOccurrence {
  const sourceRange = { from: index * 10, to: index * 10 + 8 };
  return { id: `component-${index}`, kind, title: index === 0 ? "标题 {title} {{raw}}" : `${kind} title`, sourceRange, source: `raw-${index} {source}`, previewText: index === 0 ? "预览 {preview} {{raw}}" : `preview-${index}`, lineNumber: index + 1 };
}
function render(locale: "zh-CN" | "en-US", occurrences: MarkdownSSGComponentOccurrence[], onSelect = vi.fn(), disabled = false) {
  act(() => root.render(createElement(I18nProvider, { locale, children: createElement(MarkdownSSGComponentStrip, { occurrences, onSelect, disabled }) })));
  return onSelect;
}

describe("Markdown SSG component strip localization", () => {
  it("localizes all seven controlled kinds while preserving parser data", () => {
    const occurrences = kinds.map((kind, index) => occurrence(index, kind));
    occurrences[1].title = "提示框";
    occurrences[1].previewText = "文章组件";
    const before = JSON.stringify(occurrences);
    render("en-US", occurrences);
    expect(host.querySelector("section")?.getAttribute("aria-label")).toBe("Article SSG components");
    expect(host.querySelector(".markdown-ssg-components__heading")?.textContent).toContain("Article components");
    expect([...host.querySelectorAll(".markdown-ssg-components__type")].map(node => node.textContent)).toEqual(["!Callout", "¶Lead", "▶YouTube", "▷Bilibili", "<>GitHub", "▧Image", "{}Shortcode"]);
    expect(host.textContent).toContain("标题 {title} {{raw}}");
    expect(host.textContent).toContain("预览 {preview} {{raw}}");
    expect(host.querySelectorAll("strong")[1]?.textContent).toBe("提示框");
    expect(host.querySelectorAll(".markdown-ssg-components__preview")[1]?.textContent).toBe("文章组件");
    expect(host.textContent).toContain("Line 1");
    expect(host.querySelector("button")?.getAttribute("aria-label")).toBe("Locate the Callout component on line 1: 标题 {title} {{raw}}");
    expect(JSON.stringify(occurrences)).toBe(before);
  });

  it("keeps raw range identity and uses a localized controlled callback status", () => {
    const items = [occurrence(0, "callout")];
    const onSelect = render("en-US", items);
    act(() => host.querySelector<HTMLButtonElement>("button")!.click());
    expect(onSelect).toHaveBeenCalledWith(items[0].sourceRange, "Located the Callout component on line 1.");
    expect(onSelect.mock.calls[0][0]).toBe(items[0].sourceRange);
    render("zh-CN", items, onSelect);
    act(() => host.querySelector<HTMLButtonElement>("button")!.click());
    expect(onSelect).toHaveBeenLastCalledWith(items[0].sourceRange, "已定位到第 1 行的提示框组件。");
  });

  it("relocalizes zh/en/zh while retaining nodes, focus, raw fields, and callback count", () => {
    const items = [occurrence(0, "githubCard")];
    const onSelect = render("zh-CN", items);
    const section = host.querySelector("section")!;
    const button = host.querySelector<HTMLButtonElement>("button")!;
    button.focus();
    render("en-US", items, onSelect);
    expect(host.querySelector("section")).toBe(section);
    expect(host.querySelector("button")).toBe(button);
    expect(document.activeElement).toBe(button);
    expect(host.textContent).toContain("标题 {title} {{raw}}");
    expect(onSelect).not.toHaveBeenCalled();
    render("zh-CN", items, onSelect);
    expect(host.querySelector("button")).toBe(button);
    expect(document.activeElement).toBe(button);
    expect(host.querySelector(".markdown-ssg-components__line")?.textContent).toBe("第 1 行");
    expect(onSelect).not.toHaveBeenCalled();
  });

  it("shows the first twelve items and the total count without changing raw item order", () => {
    const items = Array.from({ length: 13 }, (_, index) => occurrence(index));
    render("en-US", items);
    expect(host.querySelectorAll("[role=listitem]")).toHaveLength(12);
    expect(host.querySelector(".markdown-ssg-components__heading")?.textContent).toContain("Showing the first 12 of 13");
    expect(host.textContent).toContain("preview-11");
    expect(host.textContent).not.toContain("preview-12");
  });

  it("uses the short count message for seven items in both locales", () => {
    const items = kinds.map((kind, index) => occurrence(index, kind));
    render("en-US", items);
    expect(host.querySelector(".markdown-ssg-components__heading")?.textContent).toContain("7 components");
    render("zh-CN", items);
    expect(host.querySelector(".markdown-ssg-components__heading")?.textContent).toContain("7 个");
  });

  it("keeps empty and disabled behavior unchanged", () => {
    render("en-US", []);
    expect(host.querySelector("section")).toBeNull();
    const onSelect = render("zh-CN", [occurrence(0)], undefined, true);
    const button = host.querySelector<HTMLButtonElement>("button")!;
    expect(button.disabled).toBe(true);
    act(() => button.click());
    expect(onSelect).not.toHaveBeenCalled();
  });
});
