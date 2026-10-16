import { afterEach, describe, expect, it, vi } from "vitest";
import type { ImageReferenceInput, ImageReferenceReport } from "../../contracts/imageReferences";
import { startImageReferenceAnalysis } from "./imageReferenceAnalysis";

const input: ImageReferenceInput = {
  sources: { documents: [], totalFiles: 0, scannedFiles: 0, scannedBytes: 0, omittedFiles: 0, truncated: false, omissions: [], warnings: [] },
  images: { images: [], scannedEntries: 0, scannedBytes: 0, omittedFiles: 0, truncated: false, warnings: [] },
  repository: { siteKind: "none", contentRoot: null },
};
const report: ImageReferenceReport = { references: [], scannedDocuments: 0, omittedDocuments: 0, imageCount: 0, imagesWithoutReferences: [], partial: false, truncated: false, warnings: [] };
class FakeWorker {
  static latest: FakeWorker;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  onmessageerror: (() => void) | null = null;
  postMessage = vi.fn();
  terminate = vi.fn();
  constructor() { FakeWorker.latest = this; }
  reply(data: unknown) { this.onmessage?.({ data } as MessageEvent); }
}
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); vi.useRealTimers(); });

describe("image reference background analysis", () => {
  it("correlates replies and terminates after the matching report", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    const task = startImageReferenceAnalysis(input);
    const worker = FakeWorker.latest;
    const sent = worker.postMessage.mock.calls[0][0];
    expect(sent.input).toEqual(input);
    worker.reply({ requestId: sent.requestId + 1, report });
    expect(worker.terminate).not.toHaveBeenCalled();
    worker.reply({ requestId: sent.requestId, report });
    await expect(task.promise).resolves.toEqual(report);
    task.cancel();
    expect(worker.terminate).toHaveBeenCalledTimes(1);
  });

  it("fails closed if workers are unavailable or cannot start", async () => {
    vi.stubGlobal("Worker", undefined);
    await expect(startImageReferenceAnalysis(input).promise).rejects.toThrow("不支持");
    vi.stubGlobal("Worker", class { constructor() { throw new Error("blocked"); } });
    await expect(startImageReferenceAnalysis(input).promise).rejects.toThrow("无法启动");
  });

  it("rejects send failures and clears the worker", async () => {
    class BrokenWorker extends FakeWorker { postMessage = vi.fn(() => { throw new Error("clone"); }); }
    vi.stubGlobal("Worker", BrokenWorker);
    await expect(startImageReferenceAnalysis(input).promise).rejects.toThrow("无法发送");
    expect(FakeWorker.latest.terminate).toHaveBeenCalledTimes(1);
  });

  it("handles worker errors and malformed message delivery", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    const task = startImageReferenceAnalysis(input);
    FakeWorker.latest.onerror?.();
    await expect(task.promise).rejects.toThrow("后台图片引用分析失败");
    const second = startImageReferenceAnalysis(input);
    FakeWorker.latest.onmessageerror?.();
    await expect(second.promise).rejects.toThrow("无法读取");
    expect(FakeWorker.latest.terminate).toHaveBeenCalledTimes(1);
  });

  it("cancels or times out unresponsive analysis without main-thread fallback", async () => {
    vi.useFakeTimers(); vi.stubGlobal("Worker", FakeWorker);
    const task = startImageReferenceAnalysis(input);
    const cancelled = expect(task.promise).rejects.toThrow("已取消");
    task.cancel(); task.cancel(); await cancelled;
    expect(FakeWorker.latest.terminate).toHaveBeenCalledTimes(1);
    const second = startImageReferenceAnalysis(input);
    const timedOut = expect(second.promise).rejects.toThrow("超时");
    await vi.advanceTimersByTimeAsync(20_000); await timedOut;
    expect(FakeWorker.latest.terminate).toHaveBeenCalledTimes(1);
  });
});
