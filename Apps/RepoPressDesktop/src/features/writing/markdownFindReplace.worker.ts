import { inspectMatches, replaceAll, replaceCurrentOrNext, type FindOptions, type Match, type TextRange } from "./markdownWriting";

export interface FindReplaceWorkerRequest { requestId: number; kind: "inspect" | "preview" | "replaceCurrentOrNext"; text: string; query: string; replacement?: string; selection?: TextRange; options: FindOptions; }
export interface FindReplaceWorkerResponse { requestId: number; error: string | null; matches: Match[]; proposedText?: string; replacementCount?: number; selection?: TextRange; index?: number; total?: number; wrapped?: boolean; }
const MAX_SCOPE_LENGTH = 256 * 1024; const MAX_QUERY_LENGTH = 512; const MAX_REPLACEMENT_LENGTH = 4 * 1024; const MAX_MATCHES = 2_000;
function failure(requestId: number, error: string): FindReplaceWorkerResponse { return { requestId, error, matches: [] }; }
function validRequest(value: unknown): value is FindReplaceWorkerRequest {
  if (!value || typeof value !== "object") return false;
  const request = value as Partial<FindReplaceWorkerRequest>;
  const options = request.options as FindOptions | undefined;
  const selection = request.selection;
  return Number.isInteger(request.requestId) && (request.kind === "inspect" || request.kind === "preview" || request.kind === "replaceCurrentOrNext")
    && typeof request.text === "string" && typeof request.query === "string" && (request.replacement === undefined || typeof request.replacement === "string")
    && !!options && typeof options === "object" && [options.caseSensitive, options.wholeWord, options.regularExpression].every((item) => item === undefined || typeof item === "boolean")
    && (selection === undefined || (Number.isInteger(selection.from) && Number.isInteger(selection.to)));
}

/** Pure handler keeps real Worker behavior independently testable. */
export function executeMarkdownFindReplaceWorker(request: FindReplaceWorkerRequest): FindReplaceWorkerResponse {
  if (request.text.length > MAX_SCOPE_LENGTH) return failure(request.requestId, `范围超过 ${MAX_SCOPE_LENGTH.toLocaleString()} 个 UTF-16 字符，无法安全预览。`);
  if (!request.query) return failure(request.requestId, "请输入要查找的内容。");
  if (request.query.length > MAX_QUERY_LENGTH) return failure(request.requestId, `查找内容超过 ${MAX_QUERY_LENGTH} 个字符。`);
  if ((request.replacement ?? "").length > MAX_REPLACEMENT_LENGTH) return failure(request.requestId, `替换内容超过 ${MAX_REPLACEMENT_LENGTH.toLocaleString()} 个字符。`);
  const inspected = inspectMatches(request.text, request.query, request.options);
  if (inspected.error) return failure(request.requestId, inspected.error);
  if (inspected.matches.length > MAX_MATCHES) return failure(request.requestId, `匹配超过 ${MAX_MATCHES.toLocaleString()} 处，无法安全预览。`);
  if (request.kind === "inspect") return { requestId: request.requestId, error: null, matches: inspected.matches };
  if (request.kind === "preview") {
    const result = replaceAll(request.text, request.query, request.replacement ?? "", request.options);
    if (result.text.length > MAX_SCOPE_LENGTH) return failure(request.requestId, `替换后的范围超过 ${MAX_SCOPE_LENGTH.toLocaleString()} 个 UTF-16 字符，无法安全预览。`);
    return { requestId: request.requestId, error: null, matches: inspected.matches, proposedText: result.text, replacementCount: result.replacementCount };
  }
  if (!request.selection || !Number.isInteger(request.selection.from) || !Number.isInteger(request.selection.to)) return failure(request.requestId, "当前选择无效，请重新定位后替换。");
  const result = replaceCurrentOrNext(request.text, request.query, request.replacement ?? "", request.selection, request.options);
  if (result.text.length > MAX_SCOPE_LENGTH) return failure(request.requestId, `替换后的范围超过 ${MAX_SCOPE_LENGTH.toLocaleString()} 个 UTF-16 字符，无法安全替换。`);
  return { requestId: request.requestId, error: null, matches: inspected.matches, proposedText: result.text, replacementCount: result.replacementCount, selection: result.selection, index: result.index, total: result.total, wrapped: result.wrapped };
}
self.onmessage = (event: MessageEvent<unknown>) => { if (validRequest(event.data)) postMessage(executeMarkdownFindReplaceWorker(event.data)); };
