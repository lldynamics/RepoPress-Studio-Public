import type { ImageReferenceInput, ImageReferenceReport } from "../../contracts/imageReferences";
import { analyzeRepositoryImageReferences } from "./repositoryImageReferences";

interface WorkerScope {
  addEventListener(type: "message", listener: (event: MessageEvent<{ requestId: number; input: ImageReferenceInput }>) => void): void;
  postMessage(message: { requestId: number; report?: ImageReferenceReport; error?: string }): void;
}
const scope = globalThis as unknown as WorkerScope;
scope.addEventListener("message", ({ data }) => {
  try { scope.postMessage({ requestId: data.requestId, report: analyzeRepositoryImageReferences(data.input) }); }
  catch { scope.postMessage({ requestId: data.requestId, error: "图片引用分析失败，未生成报告。" }); }
});
