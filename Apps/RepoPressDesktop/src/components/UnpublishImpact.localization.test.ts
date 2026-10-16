import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ContentHealthSourceSnapshot } from "../contracts/repository";
import type { UnpublishImpactReport } from "../contracts/unpublishImpact";
import { analyzeUnpublishImpact } from "../features/publish/unpublishImpact";
import { I18nProvider } from "../i18n/i18n";
import { UnpublishImpactPanel, type UnpublishImpactPanelProps } from "./UnpublishImpactPanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const target = { relativePath: "标题.md", text: "---\ntitle: Title\npermalink: /target/\n---\n# Title" };
const sourceText = Array.from({ length: 240 }, (_, i) => i < 120 ? "[known](标题.md)" : "[possible](/target/)").join("\n");
const sources: ContentHealthSourceSnapshot = { documents: [
  { relativePath: target.relativePath, displayName: target.relativePath, text: target.text, byteSize: target.text.length, sha256: "target-sha" },
  { relativePath: "设置.md", displayName: "设置.md", text: sourceText, byteSize: sourceText.length, sha256: "source-sha" },
], totalFiles: 2, scannedFiles: 2, scannedBytes: sourceText.length + target.text.length, omittedFiles: 0, truncated: false, omissions: [], warnings: [] };
const analyzed = analyzeUnpublishImpact({ sources, target });
class FakeWorker {
  static instances: FakeWorker[] = [];
  onmessage: ((event: MessageEvent) => void) | null = null; onerror: (() => void) | null = null; onmessageerror: (() => void) | null = null;
  terminate = vi.fn(); postMessage = vi.fn<(value: { requestId: number }) => void>();
  constructor() { FakeWorker.instances.push(this); }
  reply(report: UnpublishImpactReport) { this.onmessage?.({ data: { requestId: this.postMessage.mock.calls[0][0].requestId, report } } as MessageEvent); }
}
let host: HTMLDivElement; let root: Root; let props: UnpublishImpactPanelProps;
let read: ReturnType<typeof vi.fn<(session: string) => Promise<ContentHealthSourceSnapshot>>>;
function render(locale: "zh-CN" | "en-US", update: Partial<UnpublishImpactPanelProps> = {}) {
  props = { ...props, ...update };
  act(() => root.render(createElement(I18nProvider, { locale, children: createElement(UnpublishImpactPanel, props) })));
}
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label)!; }
async function click(label: string) { await act(async () => button(label).click()); }
async function finish(report = analyzed) { await act(async () => FakeWorker.instances[FakeWorker.instances.length - 1].reply(report)); }

beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host); FakeWorker.instances = [];
  read = vi.fn(async () => sources);
  props = { gateway: { inspectContentHealthSources: read }, sessionId: "session", enabled: true, currentDocument: target, onLocateIssue: vi.fn() };
  vi.stubGlobal("Worker", FakeWorker);
});
afterEach(() => { act(() => root.unmount()); host.remove(); vi.unstubAllGlobals(); });

describe("Unpublish impact live localization", () => {
  it("preserves pending source reads, the Worker, filter, page, and captured text through language changes", async () => {
    let resolve!: (snapshot: ContentHealthSourceSnapshot) => void;
    read.mockImplementationOnce(() => new Promise((done) => { resolve = done; }));
    render("zh-CN"); await click("扫描下线影响"); render("en-US");
    expect(read).toHaveBeenCalledTimes(1); expect(FakeWorker.instances).toHaveLength(0);
    await act(async () => resolve(sources)); const worker = FakeWorker.instances[0];
    render("zh-CN"); expect(worker.terminate).not.toHaveBeenCalled(); expect(worker.postMessage).toHaveBeenCalledTimes(1);
    await finish();
    const filter = host.querySelector("select")!;
    await act(async () => { filter.value = "possible"; filter.dispatchEvent(new Event("change", { bubbles: true })); });
    await click("下一页"); render("en-US");
    expect(host.querySelector("select")).toBe(filter); expect(filter.value).toBe("possible");
    expect(host.textContent).toContain("Page 2 / 2"); expect(host.textContent).toContain("120 / 240");
    expect(host.textContent).toContain("Matches the target permalink, title, or name.");
    expect(host.textContent).toContain("No matches do not mean deletion or unpublishing is safe.");
    const finding = analyzed.findings.filter((item) => item.status === "possible")[100];
    const locate = host.querySelector<HTMLButtonElement>("li button")!;
    expect(locate.getAttribute("aria-label")).toBe(`Open 设置.md and locate line ${finding.line}`);
    await act(async () => locate.click());
    expect(props.onLocateIssue).toHaveBeenCalledWith("设置.md", finding.range, sourceText);
    render("zh-CN"); expect(host.textContent).toContain("第 2 / 2 页"); expect(filter.value).toBe("possible");
    expect(read).toHaveBeenCalledTimes(1); expect(FakeWorker.instances).toHaveLength(1); expect(worker.terminate).toHaveBeenCalledTimes(1);
  });

  it("keeps unmarked or mismatched warning/reason data literal, including catalog-looking text", async () => {
    render("en-US"); await click("Scan unpublish impact");
    await finish({ ...analyzed, warnings: ["设置", "untrusted warning", "<b>{page}</b>"], warningPresentations: [{ source: "设置", parameters: { unused: "x" } }, { source: "标题" }], findings: [{ ...analyzed.findings[0], reason: "设置", reasonPresentation: { source: "标题" } }] });
    expect(host.textContent).toContain("设置"); expect(host.textContent).toContain("untrusted warning"); expect(host.textContent).toContain("<b>{page}</b>");
    expect(host.querySelector("b")).toBeNull(); expect(host.textContent).not.toContain("Settings");
    expect(host.textContent).not.toContain("Title");
    render("zh-CN"); render("en-US"); expect(read).toHaveBeenCalledTimes(1); expect(host.textContent).toContain("untrusted warning");
  });

  it("retains revalidation and partial warnings across locale changes but invalidates on real source drift", async () => {
    render("zh-CN"); await click("扫描下线影响"); await finish({ ...analyzed, partial: true, omittedDocuments: 3 });
    let resolve!: (snapshot: ContentHealthSourceSnapshot) => void;
    read.mockImplementationOnce(() => new Promise((done) => { resolve = done; }));
    await click("重新核对来源"); render("en-US");
    expect(button("Recheck sources").disabled).toBe(true); expect(host.querySelector<HTMLButtonElement>("li button")!.disabled).toBe(true);
    expect(host.textContent).toContain("Zero matches do not mean deletion is safe.");
    expect(read).toHaveBeenCalledTimes(2);
    await act(async () => resolve({ ...sources, omittedFiles: 1 }));
    expect(host.textContent).toContain("The sources or current document changed."); expect(host.querySelector("li button")).toBeNull();
    render("zh-CN"); expect(host.textContent).toContain("原报告已失效"); expect(read).toHaveBeenCalledTimes(2);
  });

  it("translates tagged local Worker failures and fallbacks while retaining raw backend errors", async () => {
    vi.stubGlobal("Worker", undefined); render("zh-CN"); await click("扫描下线影响"); render("en-US");
    expect(host.textContent).toContain("Background unpublish impact analysis is unavailable");
    read.mockRejectedValueOnce(new Error("当前环境不支持后台下线影响分析，未执行检查。"));
    await click("Retry scan"); expect(host.querySelector('[role="alert"]')?.textContent).toBe("当前环境不支持后台下线影响分析，未执行检查。");
    read.mockRejectedValueOnce({}); await click("Retry scan"); expect(host.querySelector('[role="alert"]')?.textContent).toBe("Unknown error");
    render("zh-CN"); expect(host.querySelector('[role="alert"]')?.textContent).toBe("未知错误");
    expect(read).toHaveBeenCalledTimes(3);
  });
});
