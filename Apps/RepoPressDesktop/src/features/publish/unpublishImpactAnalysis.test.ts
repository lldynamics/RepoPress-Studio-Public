import { afterEach, describe, expect, it, vi } from "vitest";
import { startUnpublishImpactAnalysis, UnpublishImpactAnalysisError } from "./unpublishImpactAnalysis";

const input = { sources: { documents: [], totalFiles: 0, scannedFiles: 0, scannedBytes: 0, omittedFiles: 0, truncated: false, omissions: [], warnings: [] }, target: { relativePath: "a.md", text: "# A" } };

class FakeWorker {
  static latest: FakeWorker;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  onmessageerror: (() => void) | null = null;
  terminate = vi.fn();
  constructor() { FakeWorker.latest = this; }
  postMessage = vi.fn();
}

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

describe("startUnpublishImpactAnalysis", () => {
  it("fails closed without a Worker and never analyzes synchronously", async () => {
    vi.stubGlobal("Worker", undefined);
    await expect(startUnpublishImpactAnalysis(input).promise).rejects.toThrow("不支持");
  });

  it("cancels, ignores stale request ids, and terminates the worker", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    const task = startUnpublishImpactAnalysis(input);
    FakeWorker.latest.onmessage?.({ data: { requestId: 999, report: {} } } as MessageEvent);
    task.cancel();
    await expect(task.promise).rejects.toThrow("已取消");
    expect(FakeWorker.latest.terminate).toHaveBeenCalledTimes(1);
  });

  it("correlates a matching successful response and rejects worker errors", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    const task = startUnpublishImpactAnalysis(input);
    const report = { targetPath: "a.md", targetAvailable: true, targetEdited: false, findings: [], scannedDocuments: 0, omittedDocuments: 0, externalLinks: 0, partial: false, truncated: false, warnings: [] };
    const requestId = FakeWorker.latest.postMessage.mock.calls[0][0].requestId;
    FakeWorker.latest.onmessage?.({ data: { requestId, report } } as MessageEvent);
    await expect(task.promise).resolves.toEqual(report);
    const failed = startUnpublishImpactAnalysis(input); FakeWorker.latest.onerror?.();
    await expect(failed.promise).rejects.toThrow("后台");
    const malformed = startUnpublishImpactAnalysis(input); FakeWorker.latest.onmessageerror?.();
    await expect(malformed.promise).rejects.toThrow("无法读取");
  });

  it("rejects startup, postMessage, and error responses", async () => {
    class BrokenWorker extends FakeWorker { postMessage = vi.fn(() => { throw new Error("clone"); }); }
    vi.stubGlobal("Worker", class { constructor() { throw new Error("blocked"); } });
    await expect(startUnpublishImpactAnalysis(input).promise).rejects.toThrow("无法启动");
    vi.stubGlobal("Worker", BrokenWorker);
    await expect(startUnpublishImpactAnalysis(input).promise).rejects.toThrow("无法发送");
    vi.stubGlobal("Worker", FakeWorker);
    const task = startUnpublishImpactAnalysis(input); const requestId = FakeWorker.latest.postMessage.mock.calls[0][0].requestId; FakeWorker.latest.onmessage?.({ data: { requestId, error: "bad" } } as MessageEvent);
    await expect(task.promise).rejects.toThrow("bad");
  });

  it("times out an unresponsive worker", async () => {
    vi.useFakeTimers(); vi.stubGlobal("Worker", FakeWorker);
    const task = startUnpublishImpactAnalysis(input);
    const result = expect(task.promise).rejects.toThrow("超时");
    await vi.advanceTimersByTimeAsync(20_000);
    await result;
    expect(FakeWorker.latest.terminate).toHaveBeenCalledTimes(1);
  });

  it("tags only controlled local failures and preserves identical untagged Worker messages", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    const source = "下线影响分析失败，未生成报告。";
    const local = startUnpublishImpactAnalysis(input);
    const localResult = local.promise.catch((error) => error);
    FakeWorker.latest.onmessage?.({ data: { requestId: FakeWorker.latest.postMessage.mock.calls[0][0].requestId, error: source, errorCode: "analysisFailed" } } as MessageEvent);
    expect(await localResult).toBeInstanceOf(UnpublishImpactAnalysisError);
    expect((await localResult).presentation).toEqual({ source });
    for (const value of [{ error: source }, { error: "设置", errorCode: "analysisFailed" }]) {
      const raw = startUnpublishImpactAnalysis(input);
      const result = raw.promise.catch((error) => error);
      FakeWorker.latest.onmessage?.({ data: { requestId: FakeWorker.latest.postMessage.mock.calls[0][0].requestId, ...value } } as MessageEvent);
      expect(await result).not.toBeInstanceOf(UnpublishImpactAnalysisError);
      expect((await result).message).toBe(value.error);
    }
  });
});
