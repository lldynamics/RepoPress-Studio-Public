import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ContentHealthSourceSnapshot } from "../contracts/repository";
import { createUiTranslator, I18nProvider } from "../i18n/i18n";
import { contentHealthMessages } from "../i18n/contentHealthMessages";
import { buildRepositoryContentHealthReport, type HealthOverlay, type RepositoryContentHealthIssue } from "../features/health/repositoryContentHealth";
import { presentContentHealthIssue, RepositoryContentHealthPanel } from "./RepositoryContentHealthPanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
type Props = Parameters<typeof RepositoryContentHealthPanel>[0];
type WorkerRequest = { requestId: number; snapshot: ContentHealthSourceSnapshot; overlay?: HealthOverlay };
type WorkerReply = { requestId: number; report?: ReturnType<typeof buildRepositoryContentHealthReport>; error?: string; errorSource?: "local" };
let workers: TestWorker[];
class TestWorker {
  onmessage: ((event: MessageEvent<WorkerReply>) => void) | null = null;
  onerror: (() => void) | null = null;
  request: WorkerRequest | null = null;
  terminate = vi.fn();
  postMessage = vi.fn((request: WorkerRequest) => { this.request = request; });
  constructor() { workers.push(this); }
  reply(value: Omit<WorkerReply, "requestId">) { this.onmessage?.({ data: { requestId: this.request!.requestId, ...value } } as MessageEvent<WorkerReply>); }
}
function sourceSnapshot(): ContentHealthSourceSnapshot {
  const text = "# 原始标题\n[链接](不存在.md)";
  return { documents: [{ relativePath: "content/标题.md", displayName: "标题.md", text, byteSize: 50, sha256: "raw-sha" }], totalFiles: 2, scannedFiles: 1, scannedBytes: 50, omittedFiles: 1, truncated: true, omissions: [{ relativePath: "原始路径.md", code: "raw-code", message: "扫描结果" }], warnings: ["扫描结果", "raw {count}"] };
}
describe("content health language and report boundaries", () => {
  let host: HTMLDivElement, root: Root, props: Props;
  function render(locale: "zh-CN" | "en-US") { act(() => root.render(createElement(I18nProvider, { locale, children: createElement(RepositoryContentHealthPanel, props) }))); }
  function scan() { return host.querySelector<HTMLButtonElement>(".tool-actions button")!; }
  beforeEach(() => {
    workers = []; vi.stubGlobal("Worker", TestWorker); vi.stubGlobal("requestAnimationFrame", (callback: () => void) => { callback(); return 1; });
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    props = { active: true, enabled: true, sessionId: "session", gateway: { inspectContentHealthSources: vi.fn(async () => sourceSnapshot()) }, currentDocument: null, onOpenIssue: vi.fn() };
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.unstubAllGlobals(); });

  it("keeps pending source and worker requests, filters, raw warnings, and the frozen editor text on language round trips", async () => {
    let resolve!: (snapshot: ContentHealthSourceSnapshot) => void;
    props.gateway.inspectContentHealthSources = vi.fn(() => new Promise<ContentHealthSourceSnapshot>(done => { resolve = done; }));
    const text = "# 原始标题\n[链接](不存在.md)\n原文 {target}";
    props.currentDocument = { relativePath: "content/标题.md", text };
    render("zh-CN"); await act(async () => scan().click());
    render("en-US"); expect(scan().textContent).toBe("Scanning…"); expect(props.gateway.inspectContentHealthSources).toHaveBeenCalledTimes(1);
    await act(async () => resolve(sourceSnapshot()));
    const worker = workers[0]; render("zh-CN");
    expect(worker.postMessage).toHaveBeenCalledTimes(1); expect(worker.terminate).not.toHaveBeenCalled();
    expect(worker.request?.overlay).toEqual({ relativePath: "content/标题.md", text });
    await act(async () => worker.reply({ report: buildRepositoryContentHealthReport(worker.request!.snapshot, worker.request!.overlay) }));
    const query = host.querySelector<HTMLInputElement>('input[type="search"]')!;
    const severity = host.querySelector<HTMLSelectElement>("select")!;
    act(() => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(query, "missing-relative-link"); query.dispatchEvent(new Event("input", { bubbles: true })); severity.value = "error"; severity.dispatchEvent(new Event("change", { bubbles: true })); });
    render("en-US"); expect(host.querySelector('input[type="search"]')).toBe(query); expect(query.value).toBe("missing-relative-link"); expect(severity.value).toBe("error");
    expect(host.textContent).toContain("Partial results"); expect(host.textContent).toContain("扫描结果"); expect(host.textContent).toContain("raw {count}");
    expect(host.textContent).toContain("不存在.md was not found.");
    const issue = host.querySelector<HTMLButtonElement>(".repository-content-health-issues button")!;
    expect(issue.getAttribute("aria-label")).toContain("Relative link target was not found, locate content/标题.md");
    render("zh-CN"); expect(query.value).toBe("missing-relative-link"); expect(props.gateway.inspectContentHealthSources).toHaveBeenCalledTimes(1);
    await act(async () => issue.click()); expect(props.onOpenIssue).toHaveBeenCalledWith("content/标题.md", expect.any(Object), text);
  });

  it("translates only descriptors matching their saved source and keeps report data unchanged", () => {
    const snapshot = sourceSnapshot(); const report = buildRepositoryContentHealthReport(snapshot);
    const serialized = JSON.stringify(report); const t = createUiTranslator("en-US", contentHealthMessages);
    const generated = report.issues.find(issue => issue.code === "missing-relative-link")!;
    expect(presentContentHealthIssue(generated, t).message).toBe("不存在.md was not found.");
    const legacy: RepositoryContentHealthIssue = { ...generated, title: "扫描结果", message: "扫描结果", presentation: undefined };
    expect(presentContentHealthIssue(legacy, t)).toEqual({ title: "扫描结果", message: "扫描结果" });
    expect(presentContentHealthIssue({ ...legacy, presentation: generated.presentation }, t)).toEqual({ title: "扫描结果", message: "扫描结果" });
    const omission = report.issues.find(issue => issue.source === "scan")!;
    expect(presentContentHealthIssue(omission, t).message).toBe("raw-code: 扫描结果"); expect(JSON.stringify(report)).toBe(serialized);
  });

  it.each([undefined, "local"] as const)("keeps worker error provenance distinct (%s)", async (errorSource) => {
    render("zh-CN"); await act(async () => scan().click()); render("en-US");
    await act(async () => workers[0].reply({ error: "内容健康分析失败。", errorSource }));
    expect(host.querySelector('[role="alert"]')?.textContent).toBe(errorSource ? "Unable to scan repository content: Content health analysis failed." : "Unable to scan repository content: 内容健康分析失败。");
    render("zh-CN"); expect(host.querySelector('[role="alert"]')?.textContent).toBe("无法扫描仓库内容：内容健康分析失败。");
    expect(props.gateway.inspectContentHealthSources).toHaveBeenCalledTimes(1);
  });

  it("translates local unsupported-worker errors and keeps same-named gateway errors literal", async () => {
    vi.stubGlobal("Worker", undefined); render("zh-CN"); await act(async () => scan().click()); render("en-US");
    expect(host.textContent).toContain("Background content analysis is unsupported in this environment. No analysis ran.");
    props = { ...props, sessionId: "other", gateway: { inspectContentHealthSources: vi.fn(async () => { throw new Error("当前运行环境不支持后台内容分析；未执行分析。"); }) } };
    render("en-US"); await act(async () => scan().click());
    expect(host.querySelector('[role="alert"]')?.textContent).toBe("Unable to scan repository content: 当前运行环境不支持后台内容分析；未执行分析。");
  });
});
