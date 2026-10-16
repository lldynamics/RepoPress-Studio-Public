import { useEffect, useMemo, useRef, useState } from "react";
import type { FindOptions, Match, TextRange } from "../features/writing/markdownWriting";
import {
  applyMarkdownFindReplacePreview,
  createMarkdownFindReplacePreview,
  findScopeRange,
  freezeMarkdownSelection,
  markdownBodyScopeError,
  type FrozenMarkdownSelection,
  type MarkdownFindReplacePreview,
  type MarkdownFindReplaceScope,
} from "../features/writing/markdownFindReplacePreview";
import "./MarkdownFindReplacePanel.css";
import type { FindReplaceWorkerRequest, FindReplaceWorkerResponse } from "../features/writing/markdownFindReplace.worker";
import { parseFrontMatter } from "../features/frontmatter/frontMatter";
import { useI18n, type UiTranslator } from "../i18n/i18n";
import type { UiMessage } from "../i18n/uiMessage";
import { findError, findMessage, renderFindStatus, type FindStatus } from "./findPresentation";

type WorkerResult = FindReplaceWorkerResponse;
type WorkerRequest = Omit<FindReplaceWorkerRequest, "requestId">;

function validWorkerResult(value: unknown, sourceLength: number): value is WorkerResult {
  if (!value || typeof value !== "object") return false;
  const result = value as Partial<WorkerResult>;
  return Number.isInteger(result.requestId) && (result.error === null || typeof result.error === "string") && Array.isArray(result.matches) && result.matches.length <= 2_000
    && result.matches.every((match) => Number.isInteger(match?.from) && Number.isInteger(match?.to) && match.from >= 0 && match.to >= match.from && match.to <= sourceLength)
    && (result.proposedText === undefined || (typeof result.proposedText === "string" && result.proposedText.length <= 256 * 1024))
    && (result.replacementCount === undefined || (Number.isInteger(result.replacementCount) && result.replacementCount >= 0 && result.replacementCount <= 2_000))
    && (result.selection === undefined || (typeof result.proposedText === "string" && Number.isInteger(result.selection.from) && Number.isInteger(result.selection.to) && result.selection.from >= 0 && result.selection.to >= result.selection.from && result.selection.to <= result.proposedText.length));
}

export interface MarkdownFindReplacePanelProps {
  value: string;
  selection: TextRange;
  documentKey?: string;
  readOnly?: boolean;
  onChange: (value: string, selection: TextRange, status?: string | UiMessage) => void;
  onLocate?: (range: TextRange, expectedText: string) => void;
}

const WORKER_TIMEOUT_MS = 1_500;

function scopeLabel(scope: MarkdownFindReplaceScope, t: UiTranslator): string {
  return t(scope === "body" ? "正文（不含 Front Matter）" : "仅选区");
}

export function MarkdownFindReplacePanel({ value, selection, documentKey, readOnly = false, onChange, onLocate }: MarkdownFindReplacePanelProps) {
  const { t } = useI18n();
  const [query, setQuery] = useState("");
  const [replacement, setReplacement] = useState("");
  const [caseSensitive, setCaseSensitive] = useState(false);
  const [wholeWord, setWholeWord] = useState(false);
  const [regularExpression, setRegularExpression] = useState(false);
  const [scope, setScope] = useState<MarkdownFindReplaceScope>("body");
  const [frozenSelection, setFrozenSelection] = useState<FrozenMarkdownSelection | null>(null);
  const [matches, setMatches] = useState<Match[] | null>(null);
  const [preview, setPreview] = useState<MarkdownFindReplacePreview | null>(null);
  const [status, setStatus] = useState<FindStatus>(null);
  const requestId = useRef(0);
  const activeWorker = useRef<{ worker: Worker; timeout: number; resolve: (result: WorkerResult | null) => void } | null>(null);
  const latest = useRef({ value, documentKey: documentKey ?? "", readOnly, query, replacement, caseSensitive, wholeWord, regularExpression, scope });
  latest.current = { value, documentKey: documentKey ?? "", readOnly, query, replacement, caseSensitive, wholeWord, regularExpression, scope };
  const options = useMemo(() => ({ caseSensitive, wholeWord, regularExpression }), [caseSensitive, wholeWord, regularExpression]);

  function stopWorker() {
    requestId.current += 1;
    const active = activeWorker.current;
    if (active) { window.clearTimeout(active.timeout); active.worker.terminate(); active.resolve(null); }
    activeWorker.current = null;
  }

  useEffect(() => () => stopWorker(), []);
  useEffect(() => {
    stopWorker(); setPreview(null); setMatches(null);
    if (frozenSelection && (frozenSelection.expectedValue !== value || frozenSelection.documentKey !== (documentKey ?? ""))) {
      setFrozenSelection(null);
      if (scope === "selection") setStatus(findMessage("文稿已编辑或切换，冻结的选区已失效。"));
    }
  // A selection move is deliberately absent: navigation must not rewrite the frozen scope.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value, documentKey, readOnly]);

  function invalidatePreview() {
    stopWorker(); setPreview(null); setMatches(null); setStatus(null);
  }

  function setFindQuery(next: string) { setQuery(next); invalidatePreview(); }
  function setReplacementText(next: string) { setReplacement(next); invalidatePreview(); }
  function setOption(update: () => void) { update(); invalidatePreview(); }

  function changeScope(next: MarkdownFindReplaceScope) {
    invalidatePreview();
    setScope(next);
    if (next === "selection") {
      const snapshot = freezeMarkdownSelection(value, selection, documentKey);
      setFrozenSelection(snapshot);
      setStatus(findMessage(snapshot ? "已冻结当前选区；导航不会改变替换范围。" : "请选择正文中的非空内容；Front Matter 不能作为仅选区范围。"));
    }
  }

  function currentRange(): { range: TextRange | null; error: FindStatus } {
    if (scope === "body") {
      const issue = markdownBodyScopeError(value);
      if (issue) {
        const frontMatter = parseFrontMatter(value);
        const expectedIssue = frontMatter?.issue;
        const presentation = frontMatter?.issuePresentation;
        if (expectedIssue && presentation && issue === `无法确认正文范围：Front Matter ${expectedIssue}`) {
          return { range: null, error: findMessage("无法确认正文范围：Front Matter {issue}", undefined, { issue: presentation }) };
        }
        return { range: null, error: findError(issue) };
      }
    }
    const range = findScopeRange(value, scope, frozenSelection, documentKey);
    return { range, error: range ? null : findError("仅选区已失效，请重新选择范围。") };
  }

  function runWorker(request: WorkerRequest): Promise<WorkerResult | null> {
    stopWorker();
    const id = ++requestId.current;
    return new Promise((resolve) => {
      let worker: Worker | null = null;
      const finish = (result: WorkerResult | null) => {
        const active = activeWorker.current;
        if (active && active.worker === worker) { window.clearTimeout(active.timeout); activeWorker.current = null; }
        worker?.terminate();
        resolve(requestId.current === id ? result : null);
      };
      try {
        worker = new Worker(new URL("../features/writing/markdownFindReplace.worker.ts", import.meta.url), { type: "module" });
        const timeout = window.setTimeout(() => finish({ requestId: id, error: "查找耗时过长，已停止；请缩小范围或简化正则表达式。", matches: [] }), WORKER_TIMEOUT_MS);
        activeWorker.current = { worker, timeout, resolve };
        worker.onmessage = (event: MessageEvent<unknown>) => finish(validWorkerResult(event.data, request.text.length) && event.data.requestId === id ? event.data : { requestId: id, error: "查找工作线程返回无效结果，已拒绝本次操作。", matches: [] });
        worker.onerror = worker.onmessageerror = () => finish({ requestId: id, error: "查找工作线程不可用，已拒绝本次操作。", matches: [] });
        worker.postMessage({ ...request, requestId: id });
      } catch {
        finish({ requestId: id, error: "查找工作线程不可用，已拒绝本次操作。", matches: [] });
      }
    });
  }

  function stillCurrent(snapshot: { value: string; documentKey: string; query: string; replacement: string; options: FindOptions; scope: MarkdownFindReplaceScope }): boolean {
    const currentState = latest.current;
    return currentState.value === snapshot.value && currentState.documentKey === snapshot.documentKey
      && currentState.query === snapshot.query && currentState.replacement === snapshot.replacement
      && currentState.caseSensitive === Boolean(snapshot.options.caseSensitive) && currentState.wholeWord === Boolean(snapshot.options.wholeWord)
      && currentState.regularExpression === Boolean(snapshot.options.regularExpression) && currentState.scope === snapshot.scope;
  }

  async function inspectAndLocate(direction: "next" | "previous") {
    const { range, error } = currentRange();
    if (!range) { setStatus(error ?? findError("无法确定查找范围。")); return; }
    const snapshot = { value, documentKey: documentKey ?? "", query, replacement, options, scope };
    setPreview(null); setStatus(findMessage("正在查找…"));
    const result = await runWorker({ kind: "inspect", text: value.slice(range.from, range.to), query, options });
    if (!result || !stillCurrent(snapshot)) return;
    if (result.error) { setMatches(null); setStatus(findError(result.error)); return; }
    const found = result.matches.map((match) => ({ from: range.from + match.from, to: range.from + match.to }));
    setMatches(found);
    if (!found.length) { setStatus(findMessage("未找到匹配内容")); return; }
    const cursor = direction === "next" ? selection.to : selection.from;
    const next = direction === "next"
      ? found.find((match) => match.from >= cursor) ?? found[0]
      : [...found].reverse().find((match) => match.to <= cursor) ?? found[found.length - 1];
    const index = found.indexOf(next);
    const wrapped = direction === "next" ? next.from < cursor : next.to > cursor;
    const source = scope === "body"
      ? wrapped ? "已回绕，{index}/{total} 处 · 正文（不含 Front Matter）" : "{index}/{total} 处 · 正文（不含 Front Matter）"
      : wrapped ? "已回绕，{index}/{total} 处 · 仅选区" : "{index}/{total} 处 · 仅选区";
    setStatus(findMessage(source, { index: index + 1, total: found.length }));
    if (onLocate) onLocate(next, value); else onChange(value, next);
  }

  async function replaceOne() {
    if (readOnly) { setStatus(findMessage("文档为只读，不能替换。")); return; }
    const { range, error } = currentRange();
    if (!range) { setStatus(error ?? findError("无法确定替换范围。")); return; }
    const snapshot = { value, documentKey: documentKey ?? "", query, replacement, options, scope };
    setPreview(null); setStatus(findMessage("正在替换…"));
    const relative = { from: Math.max(0, selection.from - range.from), to: Math.max(0, selection.to - range.from) };
    const result = await runWorker({ kind: "replaceCurrentOrNext", text: value.slice(range.from, range.to), query, replacement, selection: relative, options });
    if (!result || !stillCurrent(snapshot)) return;
    if (latest.current.readOnly) { setStatus(findMessage("文档已变为只读，本次替换已取消。")); return; }
    if (result.error || !result.replacementCount || result.proposedText === undefined || !result.selection) { setStatus(result.error ? findError(result.error) : findMessage("未找到可替换的匹配内容")); return; }
    const text = value.slice(0, range.from) + result.proposedText + value.slice(range.to);
    const nextSelection = { from: range.from + result.selection.from, to: range.from + result.selection.to };
    setStatus(findMessage(result.wrapped ? "已回绕，已替换 {count} 处（原第 {index}/{total} 处）" : "已替换 {count} 处（原第 {index}/{total} 处）", { count: 1, index: (result.index ?? 0) + 1, total: result.total ?? result.replacementCount }));
    onChange(text, nextSelection, { source: "已替换 {count} 处", parameters: { count: 1 } });
  }

  async function previewAll() {
    if (readOnly) { setStatus(findMessage("文档为只读，不能预览替换。")); return; }
    const { range, error } = currentRange();
    if (!range) { setStatus(error ?? findError("无法确定替换范围。")); return; }
    const snapshot = { value, documentKey: documentKey ?? "", query, replacement, options, scope };
    setPreview(null); setStatus(findMessage("正在生成预览…"));
    const result = await runWorker({ kind: "preview", text: value.slice(range.from, range.to), query, replacement, options });
    if (!result || !stillCurrent(snapshot)) return;
    if (result.error || result.proposedText === undefined || result.replacementCount === undefined) {
      setPreview(null); setStatus(result.error ? findError(result.error) : findMessage("无法生成替换预览。")); return;
    }
    setMatches(result.matches.map((match) => ({ from: range.from + match.from, to: range.from + match.to })));
    setPreview(createMarkdownFindReplacePreview({ value, documentKey, scope, range, query, replacement, options, proposedText: result.proposedText, replacementCount: result.replacementCount }));
    setStatus(findMessage("已生成 {count} 处替换预览；尚未修改文稿。", { count: result.replacementCount }));
  }

  function applyPreview() {
    if (!preview) return;
    const result = applyMarkdownFindReplacePreview(preview, value, documentKey, readOnly);
    setPreview(null);
    if (!result.edit) { setStatus(result.error ? findError(result.error) : findMessage("预览已失效，请重新预览。")); return; }
    setStatus(findMessage("已确认替换 {count} 处，仅修改编辑缓冲区。", { count: preview.replacementCount }));
    onChange(result.edit.text, result.edit.selection, { source: "已确认替换 {count} 处", parameters: { count: preview.replacementCount } });
  }

  const scopeStatus = scope === "selection" && !frozenSelection ? t("仅选区已失效") : scopeLabel(scope, t);
  const renderedStatus = renderFindStatus(status, t);
  return <section className="markdown-find-replace" aria-label={t("查找与替换")}>
    <h2>{t("查找与替换")}</h2>
    <label>{t("查找")}<input id="markdown-document-find" value={query} onChange={(event) => setFindQuery(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.nativeEvent.isComposing) { event.preventDefault(); void inspectAndLocate(event.shiftKey ? "previous" : "next"); } }} placeholder={t("输入要查找的内容")} /></label>
    <label>{t("替换")}<input value={replacement} disabled={readOnly} onChange={(event) => setReplacementText(event.target.value)} placeholder={readOnly ? t("只读文档不可替换") : t("替换为")} /></label>
    <div className="markdown-writing-find-options">
      <label className="markdown-writing-check"><input type="checkbox" checked={caseSensitive} onChange={(event) => setOption(() => setCaseSensitive(event.target.checked))} />{t("区分大小写")}</label>
      <label className="markdown-writing-check"><input type="checkbox" checked={wholeWord} onChange={(event) => setOption(() => setWholeWord(event.target.checked))} />{t("全词匹配")}</label>
      <label className="markdown-writing-check"><input type="checkbox" checked={regularExpression} onChange={(event) => setOption(() => setRegularExpression(event.target.checked))} />{t("正则表达式")}</label>
    </div>
    <label>{t("范围")}<select value={scope} onChange={(event) => changeScope(event.target.value as MarkdownFindReplaceScope)}><option value="body">{t("正文（不含 Front Matter）")}</option><option value="selection">{t("仅选区")}</option></select></label>
    <small className="markdown-find-replace__scope">{scopeStatus}</small>
    <div className="markdown-writing-actions"><button type="button" onClick={() => void inspectAndLocate("previous")} disabled={!query}>{t("上一处")}</button><button type="button" onClick={() => void inspectAndLocate("next")} disabled={!query}>{t("下一处")}</button><button type="button" onClick={() => void replaceOne()} disabled={readOnly || !query}>{t("替换")}</button><button type="button" onClick={() => void previewAll()} disabled={readOnly || !query}>{t("预览全部替换")}</button></div>
    <small className="markdown-writing-find-status" aria-live="polite">{renderedStatus || (matches ? t("{count} 处 · {scope}", { count: matches.length, scope: scopeLabel(scope, t) }) : "")}</small>
    {preview && <div className="markdown-find-replace__preview" role="dialog" aria-label={t("全部替换预览")}><div><strong>{t("确认全部替换")}</strong><span>{t("{count} 处 · {scope}", { count: preview.replacementCount, scope: scopeLabel(preview.scope, t) })}</span></div><p>{t("以下是完整的有界纯文本范围；确认后只会写入编辑缓冲区。")}</p><div className="markdown-find-replace__columns"><label>{t("替换前")}<pre>{preview.originalText}</pre></label><label>{t("替换后")}<pre>{preview.proposedText}</pre></label></div><div className="markdown-writing-actions"><button type="button" onClick={() => { setPreview(null); setStatus(findMessage("已取消预览，文稿未改变。")); }}>{t("取消")}</button><button type="button" onClick={applyPreview} disabled={readOnly || !preview.replacementCount}>{t("确认替换")}</button></div></div>}
  </section>;
}
