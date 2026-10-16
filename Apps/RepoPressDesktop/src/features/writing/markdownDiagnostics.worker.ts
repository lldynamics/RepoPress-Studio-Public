import { getMarkdownDiagnostics, type MarkdownDiagnostic } from "./markdownDiagnostics";

export interface MarkdownDiagnosticsWorkerRequest {
  requestId: number;
  source: string;
  knownArticleTitles?: string[];
}

export interface MarkdownDiagnosticsWorkerResponse {
  requestId: number;
  diagnostics?: MarkdownDiagnostic[];
  truncated?: boolean;
  error?: string;
}

const MAX_SOURCE_LENGTH = 512 * 1024;
const MAX_KNOWN_TITLES = 20_000;
const MAX_KNOWN_TITLE_CHARACTERS = 1024 * 1024;
const MAX_DIAGNOSTICS = 500;

function requestIdOf(value: unknown): number {
  if (!value || typeof value !== "object") return 0;
  const requestId = (value as { requestId?: unknown }).requestId;
  return Number.isInteger(requestId) ? requestId as number : 0;
}

function validKnownTitles(value: unknown): value is string[] | undefined {
  if (value === undefined) return true;
  if (!Array.isArray(value) || value.length > MAX_KNOWN_TITLES) return false;
  let totalCharacters = 0;
  for (const title of value) {
    if (typeof title !== "string") return false;
    totalCharacters += title.length;
    if (totalCharacters > MAX_KNOWN_TITLE_CHARACTERS) return false;
  }
  return true;
}

function validRequest(value: unknown): value is MarkdownDiagnosticsWorkerRequest {
  if (!value || typeof value !== "object") return false;
  const request = value as Partial<MarkdownDiagnosticsWorkerRequest>;
  return Number.isInteger(request.requestId)
    && typeof request.source === "string"
    && request.source.length <= MAX_SOURCE_LENGTH
    && validKnownTitles(request.knownArticleTitles);
}

/** Pure executor used by the Worker entry point and unit tests. */
export function executeMarkdownDiagnosticsWorker(request: unknown): MarkdownDiagnosticsWorkerResponse {
  const requestId = requestIdOf(request);
  if (!validRequest(request)) return { requestId, error: "Markdown 诊断请求超出支持范围。" };
  try {
    const diagnostics = getMarkdownDiagnostics(request.source, {
      knownArticleTitles: request.knownArticleTitles,
      maxIssues: MAX_DIAGNOSTICS + 1,
    });
    return {
      requestId,
      diagnostics: diagnostics.slice(0, MAX_DIAGNOSTICS),
      truncated: diagnostics.length > MAX_DIAGNOSTICS,
    };
  } catch {
    return { requestId, error: "Markdown 诊断失败。" };
  }
}

interface WorkerScope {
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
  postMessage?: (response: MarkdownDiagnosticsWorkerResponse) => void;
}

const scope = globalThis as unknown as WorkerScope;
if (typeof document === "undefined" && typeof scope.postMessage === "function") {
  scope.onmessage = (event) => scope.postMessage?.(executeMarkdownDiagnosticsWorker(event.data));
}
