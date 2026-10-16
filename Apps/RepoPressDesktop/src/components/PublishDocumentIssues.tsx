import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { MarkdownDiagnostic, MarkdownDiagnosticRange } from "../features/writing/markdownDiagnostics";
import { useMarkdownDiagnostics } from "../features/writing/useMarkdownDiagnostics";
import { MarkdownDiagnosticsState } from "./MarkdownDiagnosticsState";
import { useI18n } from "../i18n/i18n";
import { presentDiagnostic } from "../i18n/uiMessage";

export interface PublishDocumentSource { relativePath: string; text: string; knownArticleTitles?: string[]; documentKey?: string }
export interface PublishDocumentIssuesProps {
  currentDocument?: PublishDocumentSource | null;
  onLocateIssue?: (path: string, range: MarkdownDiagnosticRange, expectedText: string) => void;
}

export function PublishDocumentIssues({ currentDocument, onLocateIssue }: PublishDocumentIssuesProps) {
  const { t } = useI18n();
  const [request, setRequest] = useState<{
    path: string; text: string; titles: string; key: string;
  } | null>(null);
  const titles = JSON.stringify(currentDocument?.knownArticleTitles ?? []);
  const key = JSON.stringify([currentDocument?.documentKey, currentDocument?.relativePath]);
  const requested = Boolean(request && currentDocument && request.path === currentDocument.relativePath
    && request.text === currentDocument.text && request.titles === titles && request.key === key);
  const session = useMarkdownDiagnostics(currentDocument?.text ?? "", key, currentDocument?.knownArticleTitles, requested);
  const isCurrent = requested && session.status === "ready";
  const binding = useRef({ key, text: currentDocument?.text, titles, session });
  useLayoutEffect(() => { binding.current = { key, text: currentDocument?.text, titles, session }; }, [key, currentDocument?.text, titles, session]);
  useEffect(() => { setRequest(null); }, [key, currentDocument?.text, titles]);

  function inspect() {
    if (!currentDocument) return;
    if (requested) session.retry();
    setRequest({ path: currentDocument.relativePath, text: currentDocument.text, titles, key });
  }
  function locate(issue: MarkdownDiagnostic, first = false) {
    const current = binding.current;
    if (!currentDocument || current.key !== key || current.text !== currentDocument.text || current.titles !== titles
      || current.session.status !== "ready" || !current.session.diagnostics.includes(issue)) return;
    const range = first ? issue.related?.range : issue.range;
    if (range) onLocateIssue?.(currentDocument.relativePath, range, session.source);
  }

  return <section className="publish-section" aria-label={t("当前文稿写作检查")}>
    <h2>{t("当前文稿写作检查")}</h2>
    <p className="publish-muted">{t("检查当前编辑内容中的常见 Markdown 问题，点击结果可返回正文。不包含站点构建、SEO 或远端发布检查。")}</p>
    {!currentDocument ? <p>{t("请先打开一篇文稿。")}</p> : <p>{currentDocument.relativePath}</p>}
    <button type="button" disabled={!currentDocument} onClick={inspect}>{t("检查当前文稿")}</button>
    {requested && <MarkdownDiagnosticsState session={session} />}
    {isCurrent && <>
      {!session.diagnostics.length && <p role="status">{t("本次本地检查未发现常见 Markdown 问题。")}</p>}
      <ol>{session.diagnostics.slice(0, 50).map((issue) => <li key={issue.id}>
        <strong>{presentDiagnostic(issue, t).title}</strong><span> · {t("第 {line} 行", { line: session.source.slice(0, issue.range.from).split("\n").length })}</span>
        <p>{presentDiagnostic(issue, t).message}</p>
        <button type="button" disabled={!onLocateIssue} onClick={() => locate(issue)}>{t("定位")}</button>
        {issue.related && <button type="button" disabled={!onLocateIssue} onClick={() => locate(issue, true)}>{t("定位首个标题")}</button>}
      </li>)}</ol>
      {session.diagnostics.length > 50 && <p className="publish-muted">{t("仅显示前 50 项，处理后请重新检查。")}</p>}
    </>}
  </section>;
}
