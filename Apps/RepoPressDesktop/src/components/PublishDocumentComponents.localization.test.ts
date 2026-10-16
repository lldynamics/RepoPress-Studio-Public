import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { GitStatusSnapshot } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { GitStatusPanel } from "./GitStatusPanel";
import { PublishDocumentIssues } from "./PublishDocumentIssues";

describe("publish and Git component localization", () => {
  let host: HTMLDivElement | undefined; let root: ReturnType<typeof createRoot> | undefined;
  afterEach(() => { act(() => root?.unmount()); host?.remove(); host = undefined; root = undefined; });
  function render(node: React.ReactNode) { host = document.createElement("div"); document.body.append(host); root = createRoot(host); act(() => { root?.render(createElement(I18nProvider, { locale: "en-US", children: node })); }); return host; }
  it("keeps report and exact locate arguments through a locale round trip", () => {
    const text = "# Title\n\n![](cover.png)"; const onLocate = vi.fn(); const node = createElement(PublishDocumentIssues, { currentDocument: { relativePath: "content/a.md", text }, onLocateIssue: onLocate }); const container = render(node); act(() => { container.querySelector<HTMLButtonElement>("button")?.click(); }); expect(container.textContent).toContain("Current document writing check"); const locate = [...container.querySelectorAll("button")].find((button) => button.textContent === "Locate"); act(() => locate?.click()); expect(onLocate.mock.calls[0][0]).toBe("content/a.md"); expect(onLocate.mock.calls[0][2]).toBe(text); act(() => { root?.render(createElement(I18nProvider, { locale: "zh-CN", children: node })); }); expect(container.textContent).toContain("当前文稿写作检查"); const locateAgain = [...container.querySelectorAll("button")].find((button) => button.textContent === "定位"); act(() => locateAgain?.click()); expect(onLocate.mock.calls[1][0]).toBe("content/a.md"); expect(onLocate.mock.calls[1][2]).toBe(text);
  });
  it("localizes Git chrome while preserving paths, patches, and unknown warnings", async () => {
    const status: GitStatusSnapshot = { available: true, branch: "feature/x", upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [{ status: "M", relativePath: "docs/a.md", sourcePath: null }], warnings: ["标题"] };
    const getDiff = vi.fn(async () => ({ relativePath: "docs/a.md", stagedPatch: "@@ raw patch", workingTreePatch: "", binary: false, truncated: false, warnings: ["设置"] }));
    const node = createElement(GitStatusPanel, { status, sessionId: "s", getDiff }); const container = render(node); const file = container.querySelector<HTMLButtonElement>(".changed-file")!; await act(async () => { file.click(); }); expect(container.textContent).toContain("Git status"); expect(container.textContent).toContain("docs/a.md"); expect(container.textContent).toContain("@@ raw patch"); expect(container.textContent).toContain("标题"); expect(container.textContent).toContain("设置"); const calls = getDiff.mock.calls.length; act(() => { root?.render(createElement(I18nProvider, { locale: "zh-CN", children: node })); }); expect(getDiff).toHaveBeenCalledTimes(calls); expect(container.textContent).toContain("@@ raw patch");
  });
  it("keeps deferred loading and rejects a stale session result", async () => {
    let resolve: ((value: { relativePath: string; stagedPatch: string; workingTreePatch: string; binary: boolean; truncated: boolean; warnings: string[] }) => void) | undefined;
    const pending = new Promise<{ relativePath: string; stagedPatch: string; workingTreePatch: string; binary: boolean; truncated: boolean; warnings: string[] }>((done) => { resolve = done; });
    const status: GitStatusSnapshot = { available: true, branch: "main", upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [{ status: "M", relativePath: "a.md", sourcePath: null }], warnings: [] };
    const getDiff = vi.fn(() => pending); const container = render(createElement(GitStatusPanel, { status, sessionId: "old", getDiff })); act(() => { container.querySelector<HTMLButtonElement>(".changed-file")?.click(); }); expect(container.textContent).toContain("Reading diff…"); act(() => { root?.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(GitStatusPanel, { status, sessionId: "old", getDiff }) })); }); expect(getDiff).toHaveBeenCalledTimes(1); expect(container.textContent).toContain("正在读取 diff…"); act(() => { root?.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(GitStatusPanel, { status, sessionId: "new", getDiff }) })); }); resolve?.({ relativePath: "a.md", stagedPatch: "stale", workingTreePatch: "", binary: false, truncated: false, warnings: [] }); await act(async () => { await pending; }); expect(container.textContent).not.toContain("stale");
  });
  it("localizes only the local fallback error and preserves raw string errors", async () => {
    const status: GitStatusSnapshot = { available: true, branch: "main", upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [{ status: "M", relativePath: "a.md", sourcePath: null }], warnings: [] };
    let rejectRequest: ((reason?: unknown) => void) | undefined;
    const getDiff = vi.fn(() => new Promise<never>((_resolve, reject) => { rejectRequest = reject; }));
    const node = createElement(GitStatusPanel, { status, sessionId: "s", getDiff }); const container = render(node); act(() => { container.querySelector<HTMLButtonElement>(".changed-file")?.click(); }); rejectRequest?.({}); await act(async () => { await Promise.resolve(); }); expect(container.textContent).toContain("Unable to read diff: Unknown error"); act(() => { root?.render(createElement(I18nProvider, { locale: "zh-CN", children: node })); }); expect(container.textContent).toContain("无法读取 diff：未知错误");
    let rejectRaw: ((reason?: unknown) => void) | undefined; const rawGetDiff = vi.fn(() => new Promise<never>((_resolve, reject) => { rejectRaw = reject; })); const rawNode = createElement(GitStatusPanel, { status, sessionId: "raw", getDiff: rawGetDiff }); act(() => { root?.render(createElement(I18nProvider, { locale: "en-US", children: rawNode })); }); act(() => { container.querySelector<HTMLButtonElement>(".changed-file")?.click(); }); rejectRaw?.("未知错误"); await act(async () => { await Promise.resolve(); }); expect(container.textContent).toContain("Unable to read diff: 未知错误");
  });
});
