import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import { getMarkdownDiagnostics } from "../features/writing/markdownDiagnostics";
import { executeMarkdownDiagnosticsWorker } from "../features/writing/markdownDiagnostics.worker";
import type { MarkdownDiagnosticsSession } from "../features/writing/useMarkdownDiagnostics";
import { MarkdownWritingInspector, type MarkdownWritingInspectorProps } from "./MarkdownWritingInspector";
import { PublishDocumentIssues } from "./PublishDocumentIssues";
import { WorkspaceStatusBar } from "./WorkspaceStatusBar";

class ControlledWorker {
  static instances: ControlledWorker[] = [];
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  onmessageerror: (() => void) | null = null;
  request: unknown;
  terminate = vi.fn();
  postMessage(request: unknown) { this.request = request; }
  constructor() { ControlledWorker.instances.push(this); }
  complete() { this.onmessage?.({ data: executeMarkdownDiagnosticsWorker(this.request) } as MessageEvent); }
}

describe("P64A diagnostic surfaces", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  let host: HTMLDivElement;
  let root: ReturnType<typeof createRoot>;
  const onChange = vi.fn();
  const onLocate = vi.fn();
  const source = "---\r\ntitle: 标题\r\n---\r\n😀 引言\r\n# 总览\r\n## 总览\r\n";
  const longSource = `${"正文".repeat(17_000)}\n# 总览\n## 总览`;
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    ControlledWorker.instances = []; vi.stubGlobal("Worker", ControlledWorker);
    onChange.mockReset(); onLocate.mockReset();
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.unstubAllGlobals(); vi.useRealTimers(); });
  function inspector(props: Partial<MarkdownWritingInspectorProps> = {}, locale: "zh-CN" | "en-US" = "zh-CN") {
    act(() => root.render(createElement(I18nProvider, { locale, children: createElement(MarkdownWritingInspector, {
      value: source, documentKey: "a", selection: { from: 0, to: 0 }, onChange, onLocate, ...props,
    }) })));
  }
  function button(label: string) {
    const element = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label);
    if (!element) throw new Error(`Missing ${label}`);
    return element;
  }
  function click(label: string) { act(() => button(label).click()); }
  async function advance(ms: number) { await act(async () => { await vi.advanceTimersByTimeAsync(ms); }); }

  it("locates both occurrences in read-only Chinese/emoji/CRLF source without offering a rename", () => {
    inspector({ readOnly: true });
    expect(host.textContent).toContain("与第 5 行的标题重复");
    const diagnostic = getMarkdownDiagnostics(source).find((item) => item.related)!;
    expect(host.querySelector(".markdown-diagnostics__actions")?.textContent).not.toContain("快速修复");
    expect(button("定位").disabled).toBe(false); click("定位");
    expect(onLocate).toHaveBeenLastCalledWith(diagnostic.range, source);
    click("定位首个标题");
    expect(onLocate).toHaveBeenLastCalledWith(diagnostic.related!.range, source);
    expect(source.slice(diagnostic.related!.range.from, diagnostic.related!.range.to)).toBe("# 总览\r");
    expect(onChange).not.toHaveBeenCalled();
    inspector({ readOnly: true }, "en-US");
    expect(host.textContent).toContain("Duplicates the heading on line 5");
    click("Locate first heading"); expect(onLocate).toHaveBeenCalledTimes(3);
  });

  it("hides supplied results whose source or document identity no longer matches", () => {
    const session: MarkdownDiagnosticsSession = { source, documentKey: "a", diagnostics: getMarkdownDiagnostics(source),
      status: "ready", truncated: false, cancel: vi.fn(), retry: vi.fn() };
    inspector({ diagnosticSession: session }); expect(button("定位首个标题")).toBeTruthy();
    inspector({ documentKey: "b", diagnosticSession: session });
    expect(host.querySelector(".markdown-diagnostics__list")).toBeNull();
    expect(host.textContent).not.toContain("未发现常见");
    inspector({ value: `${source}新正文`, diagnosticSession: session });
    expect(host.querySelector(".markdown-diagnostics__list")).toBeNull();
    expect(onLocate).not.toHaveBeenCalled();
  });

  it("shows pending/cancel/retry and real worker results while ignoring a cancelled reply", async () => {
    vi.useFakeTimers(); inspector({ value: longSource });
    expect(host.textContent).toContain("正在检查长文"); expect(host.textContent).not.toContain("未发现常见");
    await advance(200);
    const cancelled = ControlledWorker.instances[0]; const late = cancelled.onmessage!;
    click("取消检查"); expect(cancelled.terminate).toHaveBeenCalled();
    act(() => late({ data: executeMarkdownDiagnosticsWorker(cancelled.request) } as MessageEvent));
    expect(host.textContent).toContain("写作检查已取消"); expect(host.querySelector(".markdown-diagnostics__list")).toBeNull();
    click("重新检查"); await advance(200);
    act(() => ControlledWorker.instances[1].complete());
    expect(host.textContent).toContain("标题重复"); click("定位首个标题");
    expect(onLocate.mock.lastCall?.[1]).toBe(longSource); expect(onChange).not.toHaveBeenCalled();
  });

  it("does not show a clean verdict when long checks are unavailable or over the limit", async () => {
    vi.useFakeTimers(); vi.stubGlobal("Worker", undefined); inspector({ value: longSource }); await advance(200);
    expect(host.textContent).toContain("后台检查不可用"); expect(host.textContent).not.toContain("未发现常见");
    inspector({ value: "x".repeat(512 * 1024 + 1) });
    expect(host.textContent).toContain("超出本地检查上限"); expect(host.textContent).not.toContain("未发现常见");
  });

  it("keeps publish inspection explicit and uses the same cancellable long-document session", async () => {
    vi.useFakeTimers();
    const currentDocument = { relativePath: "a.md", text: longSource, documentKey: "site1:a:1" };
    function publish(document = currentDocument) { act(() => root.render(createElement(PublishDocumentIssues, { currentDocument: document, onLocateIssue: onLocate }))); }
    publish(); await advance(300); expect(ControlledWorker.instances).toHaveLength(0);
    click("检查当前文稿"); expect(host.textContent).toContain("正在检查长文"); await advance(200);
    act(() => ControlledWorker.instances[0].complete()); click("定位首个标题");
    expect(onLocate.mock.lastCall?.[0]).toBe("a.md"); expect(onLocate.mock.lastCall?.[2]).toBe(longSource);
    publish({ ...currentDocument, documentKey: "site2:a:1" });
    expect(host.querySelector("ol")).toBeNull(); expect(host.textContent).not.toContain("本次本地检查未发现");
    await advance(300); expect(ControlledWorker.instances).toHaveLength(1);
  });

  it.each(["pending", "cancelled", "unavailable", "error", "too-large"] as const)("status bar keeps %s separate from zero errors", (diagnosticStatus) => {
    const open = vi.fn();
    act(() => root.render(createElement(WorkspaceStatusBar, { document: { relativePath: "a.md", writable: true, encoding: "utf-8", lineEnding: "lf" },
      state: "saved", diagnostics: { errors: 0, warnings: 0 }, diagnosticStatus, onOpenDiagnostics: open })));
    expect(host.textContent).not.toContain("0 错误"); expect(host.textContent).not.toContain("0 警告");
    act(() => host.querySelector<HTMLButtonElement>("button")!.click()); expect(open).toHaveBeenCalledOnce();
  });

  it("marks capped counts as incomplete in the status bar and inspector", () => {
    const value = Array.from({ length: 510 }, (_, index) => `https://e.test/${index}`).join("\n");
    inspector({ value }); expect(host.textContent).toContain("超过 500 项");
    act(() => root.render(createElement(WorkspaceStatusBar, { document: { relativePath: "a.md", writable: true, encoding: "utf-8", lineEnding: "lf" },
      state: "saved", diagnostics: { errors: 0, warnings: 500 }, diagnosticStatus: "ready", diagnosticTruncated: true })));
    expect(host.querySelector("button")?.getAttribute("aria-label")).toContain("检查结果已截断");
  });
});
