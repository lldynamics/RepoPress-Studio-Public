import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { UnpublishImpactPanel, type UnpublishImpactPanelProps } from "./UnpublishImpactPanel";
import type { ContentHealthSourceSnapshot } from "../contracts/repository";
import type { UnpublishImpactReport } from "../contracts/unpublishImpact";

const sources: ContentHealthSourceSnapshot = {
  documents: [
    { relativePath: "a.md", displayName: "a.md", text: "[B](b.md)", byteSize: 9, sha256: "a" },
    { relativePath: "b.md", displayName: "b.md", text: "# B", byteSize: 3, sha256: "b" },
  ], totalFiles: 2, scannedFiles: 2, scannedBytes: 12, omittedFiles: 0, truncated: false, omissions: [], warnings: [],
};
const report: UnpublishImpactReport = {
  targetPath: "b.md", targetAvailable: true, targetEdited: false,
  findings: [{ id: "a:0", documentPath: "a.md", line: 1, range: { from: 0, to: 9 }, target: "b.md", status: "confirmed", reason: "相对路径" }],
  scannedDocuments: 2, omittedDocuments: 0, externalLinks: 0, partial: false, truncated: false, warnings: [],
};
class FakeWorker {
  static instances: FakeWorker[] = [];
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  onmessageerror: (() => void) | null = null;
  terminate = vi.fn();
  postMessage = vi.fn<(value: { requestId: number }) => void>();
  constructor() { FakeWorker.instances.push(this); }
  reply(value = report) { this.onmessage?.({ data: { requestId: this.postMessage.mock.calls[0][0].requestId, report: value } } as MessageEvent); }
}
let root: Root | null;
let container: HTMLDivElement;
let props: UnpublishImpactPanelProps;
let read: ReturnType<typeof vi.fn<() => Promise<ContentHealthSourceSnapshot>>>;
const buttons = (text: string) => [...container.querySelectorAll("button")].filter((item) => item.textContent === text);
const button = (text: string) => buttons(text)[0];
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (cause: unknown) => void; const promise = new Promise<T>((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function render(update: Partial<UnpublishImpactPanelProps> = {}) { props = { ...props, ...update }; act(() => root!.render(createElement(UnpublishImpactPanel, props))); }
async function click(text: string) { await act(async () => button(text).click()); }
async function scan(value = report) { await click("扫描下线影响"); await act(async () => FakeWorker.instances[FakeWorker.instances.length - 1].reply(value)); }

beforeEach(() => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
  read = vi.fn<() => Promise<ContentHealthSourceSnapshot>>().mockResolvedValue(sources);
  props = { enabled: true, sessionId: "s1", gateway: { inspectContentHealthSources: read }, currentDocument: { relativePath: "b.md", text: "# B" }, onLocateIssue: vi.fn() };
  FakeWorker.instances = []; vi.stubGlobal("Worker", FakeWorker); render();
});
afterEach(() => { if (root) act(() => root!.unmount()); root = null; container.remove(); vi.unstubAllGlobals(); });

describe("UnpublishImpactPanel", () => {
  it("scans only on request, prevents duplicate reads and locates the exact captured source", async () => {
    expect(read).not.toHaveBeenCalled();
    await act(async () => { button("扫描下线影响").click(); button("扫描下线影响").click(); });
    expect(read).toHaveBeenCalledTimes(1); expect(read).toHaveBeenCalledWith("s1");
    await act(async () => FakeWorker.instances[0].reply());
    expect(container.textContent).toContain("不会执行下线");
    await click("打开并定位");
    expect(props.onLocateIssue).toHaveBeenCalledWith("a.md", { from: 0, to: 9 }, "[B](b.md)");
  });

  it.each(["text", "file", "session", "enabled", "gateway", "unmount"])("discards late source reads after %s changes", async (change) => {
    const pending = deferred<ContentHealthSourceSnapshot>(); read.mockReturnValueOnce(pending.promise);
    await click("扫描下线影响");
    if (change === "unmount") { act(() => root!.unmount()); root = null; }
    else if (change === "text") render({ currentDocument: { relativePath: "b.md", text: "edited" } });
    else if (change === "file") render({ currentDocument: { relativePath: "c.md", text: "# B" } });
    else if (change === "session") render({ sessionId: "s2" });
    else if (change === "enabled") render({ enabled: false });
    else render({ gateway: { inspectContentHealthSources: vi.fn().mockResolvedValue(sources) } });
    await act(async () => pending.resolve(sources));
    expect(FakeWorker.instances).toHaveLength(0);
    expect(buttons("重新核对来源")).toHaveLength(0);
  });

  it("terminates running analysis and hides completed reports after editing", async () => {
    await click("扫描下线影响"); const worker = FakeWorker.instances[0];
    render({ currentDocument: { relativePath: "b.md", text: "edited" } });
    await act(async () => worker.reply());
    expect(worker.terminate).toHaveBeenCalledTimes(1); expect(buttons("打开并定位")).toHaveLength(0);
    await scan(); render({ currentDocument: { relativePath: "b.md", text: "edited again" } });
    expect(buttons("打开并定位")).toHaveLength(0);
  });

  it.each(["text", "sha", "added", "deleted", "omission"])("invalidates the report when revalidation detects %s drift", async (change) => {
    await scan();
    let next: ContentHealthSourceSnapshot = { ...sources, documents: sources.documents.map((item) => ({ ...item })) };
    if (change === "text") next.documents[0].text = "changed";
    if (change === "sha") next.documents[0].sha256 = "changed";
    if (change === "added") next.documents.push({ ...sources.documents[0], relativePath: "new.md" });
    if (change === "deleted") next.documents = next.documents.slice(1);
    if (change === "omission") next = { ...next, omittedFiles: 1 };
    read.mockResolvedValueOnce(next); await click("重新核对来源");
    expect(container.textContent).toContain("原报告已失效"); expect(buttons("打开并定位")).toHaveLength(0);
    expect(buttons("重新核对来源")).toHaveLength(0);
  });

  it("disables actions while checking, confirms only current evidence, and clears on failure", async () => {
    await scan(); const pending = deferred<ContentHealthSourceSnapshot>(); read.mockReturnValueOnce(pending.promise);
    await act(async () => { button("重新核对来源").click(); button("重新核对来源").click(); });
    expect(read).toHaveBeenCalledTimes(2);
    for (const label of ["扫描下线影响", "重新核对来源", "打开并定位"]) expect(button(label).disabled).toBe(true);
    expect(container.querySelector('[aria-busy="true"]')).not.toBeNull();
    await act(async () => pending.resolve(sources));
    expect(container.textContent).toContain("不保证未来状态或报告完整性");
    read.mockRejectedValueOnce(new Error("unavailable")); await click("重新核对来源");
    expect(container.textContent).toContain("原报告已失效");
    expect(container.textContent).not.toContain("本次核对时来源快照未变化");
    expect(buttons("打开并定位")).toHaveLength(0);
  });

  it("rejects late revalidation after a target switch", async () => {
    await scan(); const pending = deferred<ContentHealthSourceSnapshot>(); read.mockReturnValueOnce(pending.promise);
    await click("重新核对来源"); render({ currentDocument: { relativePath: "c.md", text: "new" } });
    await act(async () => pending.resolve(sources));
    expect(container.textContent).not.toContain("本次核对时来源快照未变化");
    expect(buttons("打开并定位")).toHaveLength(0);
  });

  it("does not grant revalidation for unavailable targets or imply safety from zero hits", async () => {
    await scan({ ...report, targetAvailable: false, partial: true, omittedDocuments: 3, externalLinks: 2, findings: [] });
    expect(button("重新核对来源").disabled).toBe(true);
    expect(container.textContent).toContain("遗漏文档 3"); expect(container.textContent).toContain("结果不完整");
    expect(container.textContent).toContain("不是安全删除保证");
    expect(container.textContent).toContain("绝对网址/外链 2");
  });

  it("offers all findings through bounded pages and resets the page when filtering", async () => {
    const findings = Array.from({ length: 205 }, (_, i) => ({ ...report.findings[0], id: String(i), target: `target-${i}`, line: i + 1 }));
    await scan({ ...report, findings });
    expect(buttons("打开并定位")).toHaveLength(100);
    await click("下一页"); expect(buttons("打开并定位")).toHaveLength(100);
    await click("下一页"); expect(buttons("打开并定位")).toHaveLength(5);
    expect(container.textContent).toContain("target-204"); expect(button("下一页").disabled).toBe(true);
    act(() => { const filter = container.querySelector("select")!; filter.value = "possible"; filter.dispatchEvent(new Event("change", { bubbles: true })); });
    expect(buttons("打开并定位")).toHaveLength(0);
    act(() => { const filter = container.querySelector("select")!; filter.value = "confirmed"; filter.dispatchEvent(new Event("change", { bubbles: true })); });
    expect(buttons("打开并定位")).toHaveLength(100); expect(button("上一页").disabled).toBe(true);
  });

  it("can retry after a worker failure without showing old results", async () => {
    await click("扫描下线影响"); await act(async () => FakeWorker.instances[0].onerror?.());
    expect(container.querySelector('[role="alert"]')).not.toBeNull(); expect(buttons("打开并定位")).toHaveLength(0);
    await click("重试扫描"); await act(async () => FakeWorker.instances[1].reply());
    expect(buttons("打开并定位")).toHaveLength(1);
  });
});
