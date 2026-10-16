import type { ImageReferenceInput, ImageReferenceReport } from "../../contracts/imageReferences";

export interface ImageReferenceAnalysisTask {
  promise: Promise<ImageReferenceReport>;
  cancel: () => void;
}
interface Response { requestId: number; report?: ImageReferenceReport; error?: string }
let nextRequestId = 0;
const ANALYSIS_TIMEOUT_MS = 20_000;

/** Analysis is always isolated so pathological Markdown can be terminated. */
export function startImageReferenceAnalysis(input: ImageReferenceInput): ImageReferenceAnalysisTask {
  let cancel = () => {};
  const promise = new Promise<ImageReferenceReport>((resolve, reject) => {
    if (typeof Worker === "undefined") {
      reject(new Error("当前环境不支持后台图片引用分析，未执行检查。"));
      return;
    }
    let worker: Worker;
    try {
      worker = new Worker(new URL("./repositoryImageReferences.worker.ts", import.meta.url), { type: "module" });
    } catch {
      reject(new Error("无法启动后台图片引用分析，未执行检查。"));
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
      if (finish()) reject(new Error("图片引用分析超时，已停止检查。请缩小内容范围后重试。"));
    }, ANALYSIS_TIMEOUT_MS);
    cancel = () => { if (finish()) reject(new Error("图片引用检查已取消。")); };
    worker.onmessage = (event: MessageEvent<Response>) => {
      if (event.data?.requestId !== requestId || !finish()) return;
      if (event.data.report) resolve(event.data.report);
      else reject(new Error(event.data.error || "图片引用分析失败。"));
    };
    worker.onerror = () => { if (finish()) reject(new Error("后台图片引用分析失败，未生成报告。")); };
    worker.onmessageerror = () => { if (finish()) reject(new Error("无法读取后台图片引用报告。")); };
    try { worker.postMessage({ requestId, input }); }
    catch { if (finish()) reject(new Error("无法发送图片引用快照，未执行检查。")); }
  });
  return { promise, cancel: () => cancel() };
}
