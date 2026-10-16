import { act, createElement, useState, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import { FrontMatterPanel } from "./FrontMatterPanel";
import { MarkdownWritingToolbar } from "./MarkdownWritingToolbar";
import { MetadataInspector } from "./MetadataInspector";
import { ResizableWorkspace } from "./ResizableWorkspace";
import { SitePreview } from "./SitePreview";
import { WorkspaceInspector } from "./WorkspaceInspector";

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;

function english(child: ReactNode) {
  return createElement(I18nProvider, { locale: "en-US", children: child });
}

function render(child: ReactNode) {
  act(() => root.render(english(child)));
}

function button(label: string) {
  const found = [...host.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === label || node.getAttribute("aria-label") === label);
  if (!found) throw new Error(`Missing button ${label}`);
  return found;
}

describe("editor component localization", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

  beforeEach(() => {
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
  });

  afterEach(() => {
    act(() => root.unmount());
    host.remove();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("localizes toolbar commands without changing the format action or selection", () => {
    const onFormat = vi.fn();
    render(createElement(MarkdownWritingToolbar, {
      value: "selected text",
      selection: { from: 2, to: 8 },
      onFormat,
    }));
    const toolbar = host.querySelector<HTMLElement>("[role='toolbar']")!;
    expect(toolbar.getAttribute("aria-label")).toBe("Markdown writing tools");
    act(() => host.querySelector<HTMLButtonElement>("button[aria-label='Bold']")!.click());
    expect(onFormat).toHaveBeenCalledExactlyOnceWith("bold");
    expect(toolbar.dataset.selection).toBe("2:8");
  });

  it("localizes Front Matter controls while preserving article field values", () => {
    const value = '---\ntitle: "中文标题"\ndescription: "原始摘要"\ntags: ["中文标签"]\n---\n正文';
    render(createElement(FrontMatterPanel, { value, selection: { from: 0, to: 0 }, onChange: vi.fn() }));
    expect(host.querySelector("[aria-label='Front Matter properties']")).not.toBeNull();
    act(() => host.querySelector<HTMLButtonElement>(".front-matter-summary")!.click());
    const titleLabel = [...host.querySelectorAll("label")].find((label) => label.textContent?.startsWith("Title"))!;
    const summaryLabel = [...host.querySelectorAll("label")].find((label) => label.textContent?.startsWith("Summary"))!;
    expect(titleLabel.querySelector<HTMLInputElement>("input")!.value).toBe("中文标题");
    expect(summaryLabel.querySelector<HTMLInputElement>("input")!.value).toBe("原始摘要");
    expect(host.textContent).toContain("Tags");
    expect(host.querySelector<HTMLInputElement>("input[placeholder='Comma-separated']")!.value).toBe("中文标签");
  });

  it("localizes metadata controls and local rule text and expires stale reports", () => {
    const onLocateField = vi.fn();
    const value = '---\ntitle: ""\ndescription: ""\n---\nBody';
    render(createElement(MetadataInspector, { value, onLocateField }));
    expect(host.querySelector("[aria-label='Front Matter SEO field check']")).not.toBeNull();
    act(() => button("Generate local report").click());
    expect(host.textContent).toContain("Title is missing");
    expect(host.textContent).toContain("Open matching field");

    render(createElement(MetadataInspector, { value: `${value}\nchanged`, onLocateField }));
    expect(host.textContent).not.toContain("Title is missing");
    expect(host.textContent).toContain("Generate local report");
  });

  it("localizes workspace ARIA and keeps the keyed editor instance while navigation changes", () => {
    vi.stubGlobal("ResizeObserver", class {
      observe() {}
      disconnect() {}
    });
    let mounts = 0;
    function StatefulEditor() {
      const [count, setCount] = useState(0);
      useState(() => { mounts += 1; return 0; });
      return createElement("button", { type: "button", "data-testid": "localized-editor", onClick: () => setCount((current) => current + 1) }, `正文 ${count}`);
    }
    const editor = createElement(StatefulEditor);
    render(createElement(ResizableWorkspace, { sidebar: createElement("aside", null, "导航"), editor }));
    const workspace = host.querySelector<HTMLElement>("#workspace-content")!;
    const editorButton = host.querySelector<HTMLButtonElement>("[data-testid='localized-editor']")!;
    expect(workspace.getAttribute("aria-label")).toBe("RepoPress editing workspace");
    expect(host.querySelector("summary")?.textContent).toBe("Repository files");
    act(() => editorButton.click());

    render(createElement(ResizableWorkspace, { sidebar: null, editor: createElement(StatefulEditor) }));
    expect(host.querySelector("[data-testid='localized-editor']")).toBe(editorButton);
    expect(editorButton.textContent).toBe("正文 1");
    expect(mounts).toBe(1);
  });

  it("localizes inspector and preview chrome while preserving supplied content and trust confirmation", async () => {
    const onSelectTab = vi.fn();
    const onClose = vi.fn();
    render(createElement(WorkspaceInspector, {
      tabs: [
        { id: "writing", label: "写作", content: createElement("p", null, "用户报告内容") },
        { id: "metadata", label: "属性与 SEO", content: createElement("p", null, "字段内容") },
      ],
      activeTab: "metadata",
      onSelectTab,
      onClose,
    }));
    expect(host.querySelector("[aria-label='Article inspector']")).not.toBeNull();
    expect(host.querySelector("[aria-label='Close article inspector']")).not.toBeNull();
    expect(host.textContent).toContain("Properties & SEO");
    expect(host.textContent).toContain("用户报告内容");

    const inspect = vi.fn().mockResolvedValue({ supported: true, runtimeAvailable: true, siteKind: "zola", executable: "zola", warning: "A real preview processes content from this trusted repository." });
    const start = vi.fn().mockResolvedValue({ running: false, url: null, message: "Preview stopped." });
    const stop = vi.fn().mockResolvedValue({ running: false, url: null, message: "Preview stopped." });
    render(createElement(SitePreview, { sessionId: "session", markdownHtml: "<p>文章正文</p>", contextKey: "context", document: null, plan: vi.fn().mockResolvedValue({planId:"plan", executable:"zola", expiresAtEpochMs:Date.now()+300000}), check: vi.fn(), inspect, start, stop }));
    await act(async () => { await Promise.resolve(); });
    expect(host.querySelector("[aria-label='Preview']")).not.toBeNull();
    act(() => button("Live site").click());
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    await act(async () => { button("Start zola").click(); await Promise.resolve(); });
    expect(confirm).toHaveBeenCalledWith("Run local zola to preview this repository. Continue only if you trust it.");
    expect(start).not.toHaveBeenCalled();
    expect(host.textContent).toContain("Live preview processes content from the local repository. Start it only for a repository you trust.");
  });
});
