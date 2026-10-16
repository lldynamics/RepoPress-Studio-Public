import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import { MarkdownImageMetadataPanel } from "./MarkdownImageMetadataPanel";
import { MarkdownOutlineActions } from "./MarkdownOutlineActions";
import { MarkdownOutlinePanel } from "./MarkdownOutlinePanel";

describe("outline and image component localization", () => {
  let host: HTMLDivElement | undefined;
  let root: ReturnType<typeof createRoot> | undefined;
  afterEach(() => { act(() => root?.unmount()); host?.remove(); host = undefined; root = undefined; });
  function render(node: React.ReactNode, locale: "zh-CN" | "en-US" = "en-US") {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => { root?.render(createElement(I18nProvider, { locale, children: node })); });
    return host;
  }
  it("localizes outline labels while preserving the user heading", () => {
    const container = render(createElement(MarkdownOutlinePanel, { value: "# 我的标题\n\n## 第二章", selection: { from: 0, to: 0 }, documentKey: "doc", onLocate: vi.fn(), onClose: vi.fn() }));
    expect(container.textContent).toContain("Article outline"); expect(container.textContent).toContain("我的标题");
  });
  it("keeps outline collapse state across a same-root locale round trip", () => {
    const node = createElement(MarkdownOutlinePanel, { value: "# Parent\n\n## Child", selection: { from: 0, to: 0 }, documentKey: "doc", onLocate: vi.fn(), onClose: vi.fn() });
    const container = render(node, "zh-CN");
    const toggle = container.querySelector<HTMLButtonElement>(".markdown-outline-panel__toggle");
    expect(toggle).toBeTruthy(); act(() => { toggle?.click(); }); expect(toggle?.getAttribute("aria-expanded")).toBe("false");
    act(() => { root?.render(createElement(I18nProvider, { locale: "en-US", children: node })); });
    act(() => { root?.render(createElement(I18nProvider, { locale: "zh-CN", children: node })); });
    expect(container.querySelector<HTMLButtonElement>(".markdown-outline-panel__toggle")?.getAttribute("aria-expanded")).toBe("false");
  });
  it("keeps read-only section navigation available while editing stays disabled", () => {
    const onCopy = vi.fn(); const container = render(createElement(MarkdownOutlineActions, { sections: [{ level: 1, title: "章节", line: 1, from: 0, to: 2, headingTo: 2 }], selectedIndex: 0, onSelect: vi.fn(), onMove: vi.fn(), onDuplicate: vi.fn(), onDelete: vi.fn(), onCopyAnchor: onCopy, anchors: ["#chapter"], readOnly: true }));
    expect(container.textContent).toContain("Move up"); expect(container.querySelectorAll("button")[1].disabled).toBe(true); expect(container.querySelectorAll("button")[5].disabled).toBe(false);
  });
  it("localizes image controls without translating path or pending input", () => {
    const container = render(createElement(MarkdownImageMetadataPanel, { value: "![旧替代](images/a.png \"旧说明\")", selection: { from: 0, to: 0 }, onChange: vi.fn() }));
    expect(container.textContent).toContain("Image metadata"); expect(container.textContent).toContain("images/a.png");
    const inputs = container.querySelectorAll<HTMLInputElement>("input");
    const setNativeValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    act(() => { setNativeValue.call(inputs[0], "未提交"); inputs[0].dispatchEvent(new Event("input", { bubbles: true })); setNativeValue.call(inputs[1], "未提交说明"); inputs[1].dispatchEvent(new Event("input", { bubbles: true })); });
    expect(inputs[0].value).toBe("未提交"); expect(inputs[1].value).toBe("未提交说明");
    const path = container.querySelector("small")?.textContent;
    act(() => { root?.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(MarkdownImageMetadataPanel, { value: "![旧替代](images/a.png \"旧说明\")", selection: { from: 0, to: 0 }, onChange: vi.fn() }) })); });
    act(() => { root?.render(createElement(I18nProvider, { locale: "en-US", children: createElement(MarkdownImageMetadataPanel, { value: "![旧替代](images/a.png \"旧说明\")", selection: { from: 0, to: 0 }, onChange: vi.fn() }) })); });
    expect(container.querySelector("small")?.textContent).toBe(path);
    expect(container.querySelectorAll<HTMLInputElement>("input")[0].value).toBe("未提交"); expect(container.querySelectorAll<HTMLInputElement>("input")[1].value).toBe("未提交说明");
  });
  it("re-renders image status after a locale switch", () => {
    const value = "---\ntitle: [\n---\n\n![alt](images/a.png)";
    const container = render(createElement(MarkdownImageMetadataPanel, { value, selection: { from: value.length, to: value.length }, onChange: vi.fn() }), "zh-CN");
    act(() => { container.querySelector<HTMLInputElement>("input[type=checkbox]")?.click(); });
    expect(container.textContent).toContain("Front Matter 当前无法安全编辑");
    act(() => { root?.render(createElement(I18nProvider, { locale: "en-US", children: createElement(MarkdownImageMetadataPanel, { value, selection: { from: value.length, to: value.length }, onChange: vi.fn() }) })); });
    expect(container.textContent).toContain("Front Matter cannot be safely edited");
  });
});
