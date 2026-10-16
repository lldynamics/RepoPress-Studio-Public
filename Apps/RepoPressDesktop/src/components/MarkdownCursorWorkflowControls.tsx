import { useEffect, useMemo, useRef, useState } from "react";
import { counterpartMarkdownFence, goToMarkdownLine, markdownCursorPosition, markdownFenceAtSelection, markdownLineCount, type MarkdownCursorRange } from "../features/writing/markdownCursorWorkflow";
import { useI18n } from "../i18n/i18n";
import "./MarkdownCursorWorkflowControls.css";

export interface MarkdownCursorWorkflowControlsProps {
  value: string;
  selection: MarkdownCursorRange;
  onSelect: (range: MarkdownCursorRange, status?: string) => void;
  openRequestKey?: number;
  disabled?: boolean;
}

export function MarkdownCursorWorkflowControls({ value, selection, onSelect, openRequestKey = 0, disabled = false }: MarkdownCursorWorkflowControlsProps) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false); const [requestedLine, setRequestedLine] = useState(""); const [error, setError] = useState("");
  const position = useMemo(() => markdownCursorPosition(value, selection), [selection, value]);
  const fence = useMemo(() => markdownFenceAtSelection(value, selection), [selection, value]);
  const lineCount = useMemo(() => markdownLineCount(value), [value]);
  const lastRequest = useRef(0);
  useEffect(() => {
    if (openRequestKey <= 0 || openRequestKey === lastRequest.current) return;
    lastRequest.current = openRequestKey;
    setRequestedLine(String(position.line)); setError(""); setOpen(true);
  }, [openRequestKey, position.line]);
  function submit() { const result = goToMarkdownLine(value, requestedLine); if (!result.range) { setError(t(result.error ?? "无法跳转。")); return; } setOpen(false); onSelect(result.range, t("已跳转到第 {line} 行。", { line: result.line ?? 0 })); }
  function jump(range: MarkdownCursorRange, label: string) { onSelect(range, label); }
  return <section className="markdown-cursor-workflow" aria-label={t("Markdown 光标工作流")}>
    <button type="button" className="markdown-cursor-workflow__position" onClick={() => { setRequestedLine(String(position.line)); setError(""); setOpen(true); }} disabled={disabled} aria-label={t("当前光标位置")}>{t("行 {line}，列 {column}", { line: position.line, column: position.column })}</button>
    {fence && <span className="markdown-cursor-workflow__fence" role="status">{fence.isClosed ? t("代码围栏：第 {start}–{end} 行", { start: fence.openingLine, end: fence.closingLine ?? fence.openingLine }) : t("代码围栏：第 {line} 行（未闭合）", { line: fence.openingLine })}</span>}
    {fence && <div className="markdown-cursor-workflow__fence-actions">
      <button type="button" onClick={() => jump(fence.opening, t("已跳转到代码围栏开头。"))} disabled={disabled}>{t("跳到开头")}</button>
      {fence.closing && <button type="button" onClick={() => jump(fence.closing!, t("已跳转到代码围栏结尾。"))} disabled={disabled}>{t("跳到结尾")}</button>}
      {fence.closing && <button type="button" onClick={() => { const range = counterpartMarkdownFence(value, selection); if (range) jump(range, t("已跳转到代码围栏对应端。")); }} disabled={disabled}>{t("跳到对应端")}</button>}
    </div>}
    {open && <div className="markdown-cursor-workflow__dialog" role="dialog" aria-label={t("跳转到指定行")}>
      <label htmlFor="markdown-go-to-line">{t("跳转到行")}</label><input id="markdown-go-to-line" inputMode="numeric" value={requestedLine} onChange={(event) => { setRequestedLine(event.target.value); setError(""); }} onKeyDown={(event) => { if (event.key === "Enter") submit(); if (event.key === "Escape") setOpen(false); }} autoFocus aria-describedby={error ? "markdown-go-to-line-error" : undefined} />
      <span>{t("共 {count} 行", { count: lineCount })}</span><button type="button" onClick={submit} disabled={disabled}>{t("确定")}</button><button type="button" onClick={() => setOpen(false)}>{t("取消")}</button>
      {error && <p id="markdown-go-to-line-error" className="markdown-cursor-workflow__error" role="alert">{error}</p>}
    </div>}
  </section>;
}
