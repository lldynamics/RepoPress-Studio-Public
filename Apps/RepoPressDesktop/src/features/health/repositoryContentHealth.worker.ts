import {
  buildRepositoryContentHealthReport,
  type HealthOverlay,
  type HealthSnapshot,
  type RepositoryContentHealthReport,
} from "./repositoryContentHealth";

interface ContentHealthWorkerRequest {
  requestId: number;
  snapshot: HealthSnapshot;
  overlay?: HealthOverlay;
}

interface ContentHealthWorkerResponse {
  requestId: number;
  report?: RepositoryContentHealthReport;
  error?: string;
  errorSource?: "local";
}

interface WorkerScope {
  addEventListener: (
    type: "message",
    listener: (event: MessageEvent<ContentHealthWorkerRequest>) => void,
  ) => void;
  postMessage: (message: ContentHealthWorkerResponse) => void;
}

const scope = globalThis as unknown as WorkerScope;

scope.addEventListener("message", (event) => {
  const { requestId, snapshot, overlay } = event.data;
  try {
    scope.postMessage({
      requestId,
      report: buildRepositoryContentHealthReport(snapshot, overlay),
    });
  } catch {
    scope.postMessage({ requestId, error: "内容健康分析失败。", errorSource: "local" });
  }
});
