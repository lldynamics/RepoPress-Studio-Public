import { act, createElement, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createUiTranslator, I18nProvider } from "../i18n/i18n";
import { presentDiagnostic, renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import { applyMarkdownDiagnosticFix, getMarkdownDiagnostics } from "../features/writing/markdownDiagnostics";
import { getMetadataDiagnostics } from "../features/frontmatter/metadataDiagnostics";
import { parseFrontMatter } from "../features/frontmatter/frontMatter";
import { MarkdownWritingInspector } from "./MarkdownWritingInspector";
import { MetadataInspector } from "./MetadataInspector";
import { FrontMatterPanel } from "./FrontMatterPanel";

const en = createUiTranslator("en-US");
const zh = createUiTranslator("zh-CN");
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
function render(child: ReactNode, locale: "zh-CN" | "en-US" = "en-US") {
  act(() => root.render(createElement(I18nProvider, { locale, children: child })));
}
function click(label: string) {
  const node = [...host.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === label);
  if (!node) throw new Error(`Missing button ${label}`);
  act(() => node.click());
}

describe("writing diagnostic presentation", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); });

  it("translates all built-in Markdown rules without altering source ranges or replacements", () => {
    const source = "# 标题\n### 设置\n## 标题\n[^标题]\n[[设置]]\n![](海报.png)\nhttps://example.test\n1、项目\n```md\ncode";
    const items = getMarkdownDiagnostics(source, { knownArticleTitles: ["Known"] });
    expect(items).toHaveLength(8);
    for (const item of items) {
      expect(presentDiagnostic(item, zh)).toEqual({ title: item.title, message: item.message });
      expect(presentDiagnostic(item, en).title).not.toBe(item.title);
      if (item.replacement !== undefined) expect(source.slice(item.range.from, item.range.to)).toBe(item.expectedText);
      else expect(item.expectedText).toBeUndefined();
    }
    expect(presentDiagnostic(items.find((item) => item.id.startsWith("missing-footnote"))!, en).message).toContain("[^标题]");
    expect(presentDiagnostic(items.find((item) => item.id.startsWith("missing-internal-link"))!, en).message).toContain("“设置”");
    const jump = items.find((item) => item.id.startsWith("heading-jump"))!;
    expect(applyMarkdownDiagnosticFix(source, jump)?.text).toContain("## 设置");
    const url = items.find((item) => item.id.startsWith("bare-url"))!;
    expect(url.replacement).toBe("[链接](https://example.test)");
    expect(applyMarkdownDiagnosticFix(source.replace("https://example.test", "https://changed.test"), url)).toBeNull();
  });

  it("localizes only tagged diagnostic labels and leaves unknown text and user parameters literal", () => {
    expect(presentDiagnostic({ title: "标题", message: "设置" }, en)).toEqual({ title: "标题", message: "设置" });
    const message: UiMessage = { source: "已修复：{title}", parameters: { title: "设置 {count}" } };
    expect(renderUiMessage(message, en)).toBe("Fixed: 设置 {count}");
    expect(renderUiMessage({ source: "已修复：{title}", labels: { title: { source: "标题层级跳跃" } } }, en)).toBe("Fixed: Heading level skipped");
  });

  it("localizes metadata and parser guidance while preserving the legacy report and exact input", () => {
    const samples = ["body", "---\ntitle: \"\"\ndescription: \"\"\n---\nbody", "---\ntitle: 短\ndescription: 短\nslug: Bad slug\npermalink: post?a\ncover: \" cover.jpg \"\n---\nbody", "---\ntitle: one\ntitle: two\n---\nbody", "---\ntitle: >\n---\nbody", "---\ntags: nope\n---\nbody", "---\ndraft: maybe\n---\nbody", "---\ntitle: [bad]\n---\nbody", "+++\ntitle = x"];
    for (const value of samples) {
      const report = getMetadataDiagnostics(value);
      expect(report.checkedBytes).toBe(new TextEncoder().encode(value).byteLength);
      for (const item of report.issues) {
        expect(presentDiagnostic(item, zh)).toEqual({ title: item.title, message: item.message });
        expect(presentDiagnostic(item, en).title).not.toBe(item.title);
        expect(presentDiagnostic(item, en).message).not.toMatch(/[\u3400-\u9fff]/);
      }
      const snapshot = parseFrontMatter(value);
      if (snapshot?.issuePresentation) expect(renderUiMessage(snapshot.issuePresentation, zh)).toBe(snapshot.issue);
    }
    const malformed = "---\ndraft: maybe\n---\n正文";
    render(createElement(FrontMatterPanel, { value: malformed, selection: { from: 0, to: 0 }, onChange: vi.fn() }));
    expect(host.textContent).toContain("Field draft must be true or false");
    render(createElement(FrontMatterPanel, { value: malformed, selection: { from: 0, to: 0 }, onChange: vi.fn() }), "zh-CN");
    expect(host.textContent).toContain("字段 draft 必须是 true 或 false");
  });

  it("keeps section selection and localized diagnostic notices through a language switch", () => {
    const value = "# 标题\n### 设置";
    const onChange = vi.fn();
    const props = { value, selection: { from: 0, to: 0 }, onChange };
    render(createElement(MarkdownWritingInspector, props));
    click("H1 标题"); click("Move up"); click("Locate");
    expect(host.textContent).toContain("Already the first section at this level");
    expect(host.textContent).toContain("Located line 2: Heading level skipped");
    render(createElement(MarkdownWritingInspector, props), "zh-CN");
    expect(host.querySelector(".markdown-outline-actions .is-selected")?.textContent).toBe("H1 标题");
    expect(host.textContent).toContain("已经是同级第一章");
    expect(host.textContent).toContain("已定位到第 2 行：标题层级跳跃");
    render(createElement(MarkdownWritingInspector, props));
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    const previousCalls = onChange.mock.calls.length;
    click("Delete");
    expect(confirm).toHaveBeenCalledWith("Delete “标题” and all its subsections?");
    expect(onChange).toHaveBeenCalledTimes(previousCalls);
    click("Quick fix");
    const [text, , notice] = onChange.mock.lastCall!;
    expect(text).toBe("# 标题\n## 设置");
    expect(renderUiMessage(notice, en)).toBe("Fixed: Heading level skipped");
    expect(renderUiMessage(notice, zh)).toBe("已修复：标题层级跳跃");
    render(createElement(MarkdownWritingInspector, { ...props, readOnly: true }));
    expect([...host.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === "Quick fix")?.disabled).toBe(true);
  });

  it("keeps a generated metadata report across locales and invalidates it only when the article changes", () => {
    const value = "---\ntitle: \"\"\ndescription: \"\"\n---\n正文";
    const onLocateField = vi.fn();
    const props = { value, onLocateField };
    render(createElement(MetadataInspector, props), "zh-CN"); click("生成本地报告");
    expect(host.textContent).toContain("缺少标题");
    render(createElement(MetadataInspector, props));
    expect(host.textContent).toContain("Title is missing"); click("Open matching field");
    expect(onLocateField).toHaveBeenCalledExactlyOnceWith("title", value);
    render(createElement(MetadataInspector, { ...props, value: `${value}\n新内容` }));
    expect(host.textContent).not.toContain("Title is missing");
    expect(host.querySelector(".metadata-inspector-report")).toBeNull();
  });
});
