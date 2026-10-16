import type { UnpublishImpactInput, UnpublishImpactReport } from "../../contracts/unpublishImpact";
import { analyzeUnpublishImpact } from "./unpublishImpact";

interface WorkerScope {
  addEventListener(type: "message", listener: (event: MessageEvent<{ requestId: number; input: UnpublishImpactInput }>) => void): void;
  postMessage(message: { requestId: number; report?: UnpublishImpactReport; error?: string; errorCode?: "analysisFailed" }): void;
}
const scope = globalThis as unknown as WorkerScope;
scope.addEventListener("message", ({ data }) => {
  try { scope.postMessage({ requestId: data.requestId, report: analyzeUnpublishImpact(data.input) }); }
  catch { scope.postMessage({ requestId: data.requestId, error: "下线影响分析失败，未生成报告。", errorCode: "analysisFailed" }); }
});
