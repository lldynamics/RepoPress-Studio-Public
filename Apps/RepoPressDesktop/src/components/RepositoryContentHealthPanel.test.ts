import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { ContentHealthSourceSnapshot } from "../contracts/repository";
import { buildRepositoryContentHealthReport, type HealthOverlay } from "../features/health/repositoryContentHealth";
import { RepositoryContentHealthPanel } from "./RepositoryContentHealthPanel";

let root: Root | null = null;
let container: HTMLDivElement | null = null;

beforeAll(() => {
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

afterEach(() => {
  if (root) act(() => root?.unmount());
  root = null;
  container?.remove();
  container = null;
  vi.unstubAllGlobals();
});

function snapshot(text = "![](cover.png)"): ContentHealthSourceSnapshot {
  return {
    documents: [{ relativePath: "content/a.md", displayName: "a.md", text, byteSize: text.length, sha256: "sha" }],
    totalFiles: 1,
    scannedFiles: 1,
    scannedBytes: text.length,
    omittedFiles: 0,
    truncated: false,
    omissions: [],
    warnings: [],
  };
}

function mount(props: Parameters<typeof RepositoryContentHealthPanel>[0]) {
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => { callback(0); return 1; });
  vi.stubGlobal("Worker", class TestContentHealthWorker {
    onmessage: ((event: MessageEvent) => void) | null = null;
    onerror: ((event: Event) => void) | null = null;
    terminated = false;
    postMessage(request: { requestId: number; snapshot: ContentHealthSourceSnapshot; overlay?: HealthOverlay }) {
      queueMicrotask(() => {
        if (this.terminated) return;
        this.onmessage?.({ data: {
          requestId: request.requestId,
          report: buildRepositoryContentHealthReport(request.snapshot, request.overlay),
        } } as MessageEvent);
      });
    }
    terminate() { this.terminated = true; }
  });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  act(() => root?.render(createElement(RepositoryContentHealthPanel, props)));
}

function button(label: string): HTMLButtonElement {
  const match = [...(container?.querySelectorAll("button") ?? [])].find((item) => item.textContent?.includes(label));
  if (!match) throw new Error(`missing button ${label}`);
  return match;
}

async function click(element: HTMLElement) {
  await act(async () => {
    element.click();
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe("RepositoryContentHealthPanel", () => {
  it("waits for explicit consent, then renders and locates a local issue", async () => {
    const inspectContentHealthSources = vi.fn().mockResolvedValue(snapshot());
    const onOpenIssue = vi.fn();
    mount({ active: true, enabled: true, sessionId: "session-1", gateway: { inspectContentHealthSources }, currentDocument: null, onOpenIssue });

    expect(inspectContentHealthSources).not.toHaveBeenCalled();
    expect(container?.textContent).toContain("尚未扫描");
    await click(button("扫描仓库内容"));

    expect(inspectContentHealthSources).toHaveBeenCalledWith("session-1");
    expect(container?.textContent).toContain("完整结果");
    await click(button("图片缺少 alt 文本"));
    expect(onOpenIssue).toHaveBeenCalledWith(
      "content/a.md",
      expect.objectContaining({ from: 1 }),
      "![](cover.png)",
    );
  });

  it("drops a stale response after the repository session changes", async () => {
    let resolveFirst!: (value: ContentHealthSourceSnapshot) => void;
    const first = new Promise<ContentHealthSourceSnapshot>((resolve) => { resolveFirst = resolve; });
    const inspectContentHealthSources = vi.fn().mockReturnValueOnce(first).mockResolvedValueOnce(snapshot("https://second.test"));
    const props = { active: true, enabled: true, gateway: { inspectContentHealthSources }, currentDocument: null, onOpenIssue: vi.fn() };
    mount({ ...props, sessionId: "session-a" });
    await click(button("扫描仓库内容"));

    await act(async () => {
      root?.render(createElement(RepositoryContentHealthPanel, { ...props, sessionId: "session-b" }));
      await Promise.resolve();
    });
    resolveFirst(snapshot("https://stale.test"));
    await act(async () => { await first; await Promise.resolve(); });
    expect(container?.textContent).toContain("尚未扫描");
    expect(container?.textContent).not.toContain("扫描结果");

    await click(button("扫描仓库内容"));
    expect(inspectContentHealthSources).toHaveBeenLastCalledWith("session-b");
    expect(container?.textContent).toContain("扫描结果");
  });

  it("keeps scan-level omissions visible but non-locatable", async () => {
    const partial = { ...snapshot("正文"), omittedFiles: 1, omissions: [{ relativePath: "content/large.md", code: "too-large", message: "超出限制" }] };
    mount({ active: true, enabled: true, sessionId: "session-1", gateway: { inspectContentHealthSources: vi.fn().mockResolvedValue(partial) }, currentDocument: null, onOpenIssue: vi.fn() });
    await click(button("扫描仓库内容"));

    expect(container?.textContent).toContain("部分结果");
    expect(container?.textContent).toContain("不可定位");
    expect([...container!.querySelectorAll("button")].some((item) => item.textContent?.includes("部分源文件不可用"))).toBe(false);
  });

  it("fails closed when background analysis is unavailable", async () => {
    mount({ active: true, enabled: true, sessionId: "session-1", gateway: { inspectContentHealthSources: vi.fn().mockResolvedValue(snapshot()) }, currentDocument: null, onOpenIssue: vi.fn() });
    vi.stubGlobal("Worker", undefined);
    await click(button("扫描仓库内容"));
    expect(container?.textContent).toContain("不支持后台内容分析");
    expect(container?.textContent).not.toContain("扫描结果");
  });

  it("distinguishes an unavailable capability from a missing repository", async () => {
    const inspectContentHealthSources = vi.fn();
    mount({ active: true, enabled: false, sessionId: null, gateway: { inspectContentHealthSources }, currentDocument: null, onOpenIssue: vi.fn() });
    expect(container?.textContent).toContain("当前运行环境未提供本地内容健康扫描");
    expect(button("扫描仓库内容").disabled).toBe(true);
    await click(button("扫描仓库内容"));
    expect(inspectContentHealthSources).not.toHaveBeenCalled();
  });
});
