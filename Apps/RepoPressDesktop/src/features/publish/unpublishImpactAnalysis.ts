import type { UnpublishImpactInput, UnpublishImpactReport } from "../../contracts/unpublishImpact";

export interface UnpublishImpactAnalysisTask {
  promise: Promise<UnpublishImpactReport>;
  cancel: () => void;
}

interface WorkerResponse { requestId: number; report?: UnpublishImpactReport; error?: string; errorCode?: "analysisFailed" }
export class UnpublishImpactAnalysisError extends Error {
  readonly presentation: { source: string };
  constructor(source: string) { super(source); this.presentation = { source }; }
}
let nextRequestId = 0;
const ANALYSIS_TIMEOUT_MS = 20_000;

/** Run impact analysis in an isolated worker. There is deliberately no main-thread fallback. */
export function startUnpublishImpactAnalysis(input: UnpublishImpactInput): UnpublishImpactAnalysisTask {
  let cancel = () => {};
  const promise = new Promise<UnpublishImpactReport>((resolve, reject) => {
    if (typeof Worker === "undefined") {
      reject(new UnpublishImpactAnalysisError("当前环境不支持后台下线影响分析，未执行检查。"));
      return;
    }
    let worker: Worker;
    try {
      worker = new Worker(new URL("./unpublishImpact.worker.ts", import.meta.url), { type: "module" });
    } catch {
      reject(new UnpublishImpactAnalysisError("无法启动后台下线影响分析，未执行检查。"));
      return;
    }
    const requestId = ++nextRequestId;
    let settled = false;
    const finish = () => {
      if (settled) return false;
      settled = true;
      clearTimeout(timeout);
      worker.onmessage = null;
      worker.onerror = null;
      worker.onmessageerror = null;
      worker.terminate();
      return true;
    };
    const timeout = setTimeout(() => {
      if (finish()) reject(new UnpublishImpactAnalysisError("下线影响分析超时，已停止检查。请缩小内容范围后重试。"));
    }, ANALYSIS_TIMEOUT_MS);
    cancel = () => { if (finish()) reject(new UnpublishImpactAnalysisError("下线影响检查已取消。")); };
    worker.onmessage = (event: MessageEvent<WorkerResponse>) => {
      if (event.data?.requestId !== requestId || !finish()) return;
      if (event.data.report) resolve(event.data.report);
      else {
        const fallback = "下线影响分析失败，未生成报告。";
        reject(!event.data.error || (event.data.errorCode === "analysisFailed" && event.data.error === fallback)
          ? new UnpublishImpactAnalysisError(fallback) : new Error(event.data.error));
      }
    };
    worker.onerror = () => { if (finish()) reject(new UnpublishImpactAnalysisError("后台下线影响分析失败，未生成报告。")); };
    worker.onmessageerror = () => { if (finish()) reject(new UnpublishImpactAnalysisError("无法读取后台下线影响报告。")); };
    try { worker.postMessage({ requestId, input }); }
    catch { if (finish()) reject(new UnpublishImpactAnalysisError("无法发送下线影响快照，未执行检查。")); }
  });
  return { promise, cancel: () => cancel() };
}
