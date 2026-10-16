import { createElement } from "react";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { WorkspaceStatusBar } from "./WorkspaceStatusBar";
import { I18nProvider } from "../i18n/i18n";

const documentInfo = { relativePath: "posts/hello.md", writable: true, encoding: "UTF-8", lineEnding: "LF" };
const stats = { words: 12, characters: 45, lines: 3, readingMinutes: 1 };

describe("WorkspaceStatusBar", () => {
  let host: HTMLDivElement | undefined;
  let root: ReturnType<typeof createRoot> | undefined;
  afterEach(() => { act(() => root?.unmount()); host?.remove(); root = undefined; host = undefined; });
  function render(props: Partial<Parameters<typeof WorkspaceStatusBar>[0]> = {}) {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => { root?.render(createElement(WorkspaceStatusBar, { state: "saved", ...props })); });
    return host.querySelector<HTMLElement>(".workspace-status-bar")!;
  }
  it("does not report saved or zero issues without a document", () => {
    const bar = render({ state: "saved", diagnostics: { errors: 0, warnings: 0 }, stats });
    expect(bar.textContent).toContain("未打开文档"); expect(bar.textContent).not.toContain("已保存"); expect(bar.textContent).not.toContain("0 错误");
  });
  it("keeps dirty/conflict state visible for read-only documents", () => {
    const bar = render({ document: { ...documentInfo, writable: false }, state: "conflict" });
    expect(bar.textContent).toContain("只读"); expect(bar.textContent).toContain("保存冲突");
    act(() => root?.render(createElement(WorkspaceStatusBar, { document: { ...documentInfo, writable: false }, state: "saved" })));
    expect(bar.textContent).toContain("只读"); expect(bar.textContent).not.toContain("刚刚保存");
    act(() => root?.render(createElement(WorkspaceStatusBar, { document: { ...documentInfo, writable: false }, state: "dirty" })));
    expect(bar.textContent).toContain("有未保存修改");
  });
  it("updates status, stats, and exact format labels", () => {
    const bar = render({ document: { ...documentInfo, encoding: "utf-8", lineEnding: "mixed" }, state: "dirty", stats: { ...stats, words: 20 }, diagnostics: { errors: 1, warnings: 2 } });
    expect(bar.textContent).toContain("有未保存修改"); expect(bar.textContent).toContain("20 字词"); expect(bar.textContent).toContain("UTF-8"); expect(bar.textContent).toContain("混合换行");
    act(() => root?.render(createElement(WorkspaceStatusBar, { document: { ...documentInfo, encoding: "custom", lineEnding: "none" }, state: "clean" })));
    expect(bar.textContent).toContain("custom"); expect(bar.textContent).toContain("无换行");
  });
  it("opens diagnostics and respects disabled", () => {
    const onOpenDiagnostics = vi.fn(); const bar = render({ document: documentInfo, diagnostics: { errors: 1, warnings: 0 }, onOpenDiagnostics });
    const button = bar.querySelector<HTMLButtonElement>(".workspace-status-bar__diagnostics")!; act(() => { button.click(); }); expect(onOpenDiagnostics).toHaveBeenCalledTimes(1);
    act(() => root?.render(createElement(WorkspaceStatusBar, { document: documentInfo, state: "saving", diagnostics: { errors: 1, warnings: 0 }, onOpenDiagnostics, disabled: true }))); expect(button.disabled).toBe(true);
  });
  it("renders English status labels while preserving the path and disabled diagnostics", () => {
    const onOpenDiagnostics = vi.fn();
    act(() => { root?.unmount(); host?.remove(); host = document.createElement("div"); document.body.append(host); root = createRoot(host); root.render(createElement(I18nProvider, { locale: "en-US", children: createElement(WorkspaceStatusBar, { document: documentInfo, state: "dirty", diagnostics: { errors: 2, warnings: 1 }, onOpenDiagnostics, disabled: true }) })); });
    const bar = host!.querySelector<HTMLElement>(".workspace-status-bar")!;
    expect(bar.textContent).toContain("Unsaved changes"); expect(bar.textContent).toContain(documentInfo.relativePath);
    expect(bar.querySelector<HTMLButtonElement>(".workspace-status-bar__diagnostics")?.disabled).toBe(true);
  });
  it("translates mixed and absent line endings in English", () => {
    render();
    for (const [lineEnding, expected] of [["mixed", "Mixed line endings"], ["none", "No line ending"]]) {
      act(() => root?.render(createElement(I18nProvider, { locale: "en-US", children: createElement(WorkspaceStatusBar, { document: { ...documentInfo, lineEnding }, state: "clean" }) })));
      expect(host?.textContent).toContain(expected);
      expect(host?.textContent).toContain(documentInfo.relativePath);
    }
  });

});
