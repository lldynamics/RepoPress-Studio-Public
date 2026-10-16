import { useEffect, useId, useMemo, useRef, useState } from "react";
import { createUiTranslator, useI18n, type UiTranslator } from "../i18n/i18n";
import { presentDiagnostic, renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import { contentHealthMessages } from "../i18n/contentHealthMessages";
import type { ContentHealthSourceSnapshot, RepositoryGateway } from "../contracts/repository";
import {
  type RepositoryContentHealthIssue,
  type RepositoryContentHealthReport,
} from "../features/health/repositoryContentHealth";
import "./RepositoryContentHealthPanel.css";

type ScanState = "idle" | "loading" | "success" | "error";
export type ContentHealthSeverityFilter = "all" | "error" | "warning";
type EditorOverlay = RepositoryContentHealthPanelProps["currentDocument"];
type ScopedSnapshot = { sessionId: string; value: ContentHealthSourceSnapshot; overlay: EditorOverlay };
interface ContentHealthAnalysisTask { cancel: () => void }
const MAX_RENDERED_ISSUES = 500;

export interface RepositoryContentHealthPanelProps {
  active: boolean;
  enabled: boolean;
  sessionId: string | null;
  gateway: Pick<RepositoryGateway, "inspectContentHealthSources">;
  currentDocument: { relativePath: string; text: string } | null;
  onOpenIssue: (relativePath: string, range: { from: number; to: number }, expectedDocumentText: string) => void;
}

export function RepositoryContentHealthPanel({
  active,
  enabled,
  sessionId,
  gateway,
  currentDocument,
  onOpenIssue,
}: RepositoryContentHealthPanelProps) {
  const { t, locale } = useI18n(contentHealthMessages);
  const [scopedSnapshot, setScopedSnapshot] = useState<ScopedSnapshot | null>(null);
  const [report, setReport] = useState<RepositoryContentHealthReport | null>(null);
  const [scanState, setScanState] = useState<ScanState>("idle");
  const [errorMessage, setErrorMessage] = useState<UiMessage | null>(null);
  const [severity, setSeverity] = useState<ContentHealthSeverityFilter>("all");
  const [query, setQuery] = useState("");
  const generation = useRef(0);
  const analysisWorker = useRef<ContentHealthAnalysisTask | null>(null);
  const resultsHeading = useRef<HTMLHeadingElement>(null);
  const id = useId();
  const resultsHeadingId = `${id}-results`;
  const findingsHeadingId = `${id}-findings`;
  const severityId = `${id}-severity`;
  const queryId = `${id}-query`;
  const snapshot = scopedSnapshot?.sessionId === sessionId ? scopedSnapshot.value : null;

  useEffect(() => {
    generation.current += 1;
    analysisWorker.current?.cancel();
    analysisWorker.current = null;
    setScopedSnapshot(null);
    setReport(null);
    setScanState("idle");
    setErrorMessage(null);
    setSeverity("all");
    setQuery("");
    return () => {
      generation.current += 1;
      analysisWorker.current?.cancel();
      analysisWorker.current = null;
    };
  }, [active, enabled, sessionId]);

  const visibleIssues = useMemo(
    () => filterRepositoryContentHealthIssues(report?.issues ?? [], severity, query),
    [query, report, severity],
  );
  const renderedIssues = visibleIssues.slice(0, MAX_RENDERED_ISSUES);
  const scannedDocumentText = useMemo(() => {
    const values = new Map<string, string>();
    for (const document of snapshot?.documents ?? []) {
      const relativePath = normalizedRepositoryPath(document.relativePath);
      const overlay = scopedSnapshot?.overlay;
      values.set(
        relativePath,
        overlay && normalizedRepositoryPath(overlay.relativePath) === relativePath ? overlay.text : document.text,
      );
    }
    return values;
  }, [scopedSnapshot?.overlay, snapshot]);

  async function scanRepository() {
    if (!enabled || !sessionId || scanState === "loading") return;
    const requestedSession = sessionId;
    const requestedOverlay = currentDocument ? { ...currentDocument } : null;
    const current = ++generation.current;
    setScopedSnapshot(null);
    setReport(null);
    setErrorMessage(null);
    setScanState("loading");
    try {
      const nextSnapshot = await gateway.inspectContentHealthSources(requestedSession);
      if (current !== generation.current) return;
      const nextReport = await analyzeRepositoryContentHealthOffMainThread(
        nextSnapshot,
        requestedOverlay,
        current,
        analysisWorker,
      );
      if (current !== generation.current) return;
      setScopedSnapshot({ sessionId: requestedSession, value: nextSnapshot, overlay: requestedOverlay });
      setReport(nextReport);
      setScanState("success");
      requestAnimationFrame(() => {
        if (current === generation.current) resultsHeading.current?.focus();
      });
    } catch (error) {
      if (current !== generation.current) return;
      analysisWorker.current?.cancel();
      analysisWorker.current = null;
      setScanState("error");
      setErrorMessage(scanError(error));
    }
  }

  if (!active) return null;

  const incomplete = Boolean(report?.partial || report?.truncatedIssues);
  const scannedOverlay = scopedSnapshot?.sessionId === sessionId ? scopedSnapshot.overlay : null;
  const overlaysCurrentDocument = Boolean(scannedOverlay && snapshot?.documents.some(
    (document) => normalizedRepositoryPath(document.relativePath) === normalizedRepositoryPath(scannedOverlay.relativePath),
  ));
  return <section
    className="advanced-panel repository-content-health-panel"
    aria-label={t("仓库内容健康")}
    aria-busy={scanState === "loading"}
  >
    <div className="advanced-heading repository-content-health-heading">
      <div>
        <strong>{t("仓库内容健康")}</strong>
        <p>{t("仅在你明确扫描后读取本地 Markdown；分析不联网、不写盘，也不会修改文稿。")}</p>
      </div>
      <div className="repository-content-health-badges" aria-label={t("分析边界")}>
        <span className="tool-badge">{t("本地")}</span>
        <span className="tool-badge">{t("只读")}</span>
        <span className="tool-badge">{t("不联网")}</span>
        <span className="tool-badge">{t("不写盘")}</span>
      </div>
    </div>

    <div className="tool-actions">
      <button
        type="button"
        onClick={() => void scanRepository()}
        disabled={!enabled || !sessionId || scanState === "loading"}
      >
        {scanState === "loading" ? t("正在扫描…") : scanState === "error" ? t("重试扫描") : t("扫描仓库内容")}
      </button>
    </div>

    {!enabled && <p className="tool-muted">{t("当前运行环境未提供本地内容健康扫描；不会读取仓库。")}</p>}
    {enabled && !sessionId && <p className="tool-muted">{t("请先打开本地仓库；此面板不会自动选择或扫描目录。")}</p>}
    {enabled && sessionId && scanState === "idle" && <p className="tool-muted">{t("尚未扫描。当前仓库内容不会在后台自动读取。")}</p>}
    <div className="repository-content-health-status" aria-live="polite" aria-atomic="true">
      {scanState === "loading" && <p className="tool-state" role="status">{t("正在本地读取并分析仓库内容…")}</p>}
      {scanState === "error" && errorMessage && <p className="tool-error" role="alert">{renderUiMessage(errorMessage, t)}</p>}
    </div>

    {report && snapshot && <>
      <section
        className="tool-subsection repository-content-health-summary"
        aria-labelledby={resultsHeadingId}
      >
        <div className="repository-content-health-summary-heading">
          <h2 id={resultsHeadingId} ref={resultsHeading} tabIndex={-1}>{t("扫描结果")}</h2>
          <span className={incomplete ? "repository-content-health-completeness partial" : "repository-content-health-completeness complete"}>
            {incomplete ? t("部分结果") : t("完整结果")}
          </span>
        </div>
        <dl className="repository-content-health-metrics">
          <div>
            <dt>{t("文件")}</dt>
            <dd title={t("发现 {total} 个，读取 {scanned} 个", { total: snapshot.totalFiles, scanned: snapshot.scannedFiles })}>
              {formatContentHealthCount(report.summary.documentCount, locale)} / {formatContentHealthCount(snapshot.totalFiles, locale)}
            </dd>
          </div>
          <div><dt>{t("已分析")}</dt><dd>{formatContentHealthBytes(report.summary.scannedBytes, locale)}</dd></div>
          <div className="error"><dt>Error</dt><dd>{formatContentHealthCount(report.summary.errorCount, locale)}</dd></div>
          <div className="warning"><dt>Warning</dt><dd>{formatContentHealthCount(report.summary.warningCount, locale)}</dd></div>
        </dl>
        {incomplete && <div className="repository-content-health-incomplete" role="alert">
          <strong>{t("结果不完整")}</strong>
          <span>{t("源扫描存在截断或遗漏，未显示的问题不能视为已通过检查。")}</span>
          {snapshot.truncated && <span>{t("扫描已达到读取上限。")}</span>}
          {snapshot.omittedFiles > 0 && <span>{t("有 {count} 个文件未能读取。", { count: formatContentHealthCount(snapshot.omittedFiles, locale) })}</span>}
          {report.truncatedIssues && <span>{t("问题列表已达到显示上限，另有问题未显示。")}</span>}
        </div>}
        {snapshot.warnings.length > 0 && <div className="repository-content-health-source-warnings" aria-label={t("扫描警告")}>
          {snapshot.warnings.map((warning, index) => <p className="tool-warning" key={`${index}:${warning}`}>{warning}</p>)}
        </div>}
        {overlaysCurrentDocument && scannedOverlay && <p className="tool-muted">
          {t("{path} 使用扫描开始时的编辑器内存内容覆盖磁盘快照；没有写入文件。继续编辑后请重新扫描以刷新报告。", { path: scannedOverlay.relativePath })}</p>}
      </section>

      <section className="repository-content-health-findings" aria-labelledby={findingsHeadingId}>
        <div className="repository-content-health-findings-heading">
          <h2 id={findingsHeadingId}>{t("问题列表")}</h2>
          <span>{visibleIssues.length} / {report.issues.length}</span>
        </div>
        <div className="repository-content-health-filters" role="search" aria-label={t("筛选内容健康问题")}>
          <label htmlFor={severityId}>{t("严重级")}</label>
          <select
            id={severityId}
            value={severity}
            onChange={(event) => setSeverity(event.target.value as ContentHealthSeverityFilter)}
          >
            <option value="all">{t("全部")}</option>
            <option value="error">Error</option>
            <option value="warning">Warning</option>
          </select>
          <label htmlFor={queryId}>{t("文本")}</label>
          <input
            id={queryId}
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            maxLength={200}
            placeholder={t("标题、说明、路径或代码")}
          />
        </div>
        {report.issues.length === 0
          ? <p className="repository-content-health-empty" role="status">{t("在本次{scope}扫描范围内没有发现问题。", { scope: incomplete ? t("部分") : t("完整") })}</p>
          : visibleIssues.length === 0
            ? <p className="tool-muted" role="status">{t("没有符合当前筛选条件的问题。")}</p>
            : <>
              {visibleIssues.length > MAX_RENDERED_ISSUES && <p className="tool-warning" role="status">
                {t("当前筛选匹配 {count} 条，仅显示前 {limit} 条；请缩小筛选条件以定位其他问题。", { count: formatContentHealthCount(visibleIssues.length, locale), limit: formatContentHealthCount(MAX_RENDERED_ISSUES, locale) })}</p>}
              <IssueList issues={renderedIssues} documentText={scannedDocumentText} onOpenIssue={onOpenIssue} />
            </>}
      </section>
    </>}
  </section>;
}

function IssueList({
  issues,
  documentText,
  onOpenIssue,
}: {
  issues: RepositoryContentHealthIssue[];
  documentText: ReadonlyMap<string, string>;
  onOpenIssue: RepositoryContentHealthPanelProps["onOpenIssue"];
}) {
  const { t } = useI18n(contentHealthMessages);
  return <ol className="repository-content-health-issues" aria-label={t("内容健康问题")}>
    {issues.map((issue) => {
      const displayed = presentContentHealthIssue(issue, t);
      const expectedDocumentText = issue.relativePath
        ? documentText.get(normalizedRepositoryPath(issue.relativePath))
        : undefined;
      const canOpen = Boolean(issue.source !== "scan" && issue.relativePath && expectedDocumentText !== undefined);
      const content = <IssueContent issue={issue} canOpen={canOpen} />;
      return <li key={issue.id} className={`repository-content-health-issue ${issue.severity}`}>
        {canOpen
          ? <button
            type="button"
            onClick={() => expectedDocumentText !== undefined
              && onOpenIssue(issue.relativePath!, issue.range, expectedDocumentText)}
            aria-label={t("{title}，定位到 {path}{line}", { title: displayed.title, path: issue.relativePath!, line: issue.line ? t(" 第 {line} 行", { line: issue.line }) : "" })}
          >{content}</button>
          : <article aria-label={t("{title}，不可定位", { title: displayed.title })}>{content}</article>}
      </li>;
    })}
  </ol>;
}

function IssueContent({ issue, canOpen }: { issue: RepositoryContentHealthIssue; canOpen: boolean }) {
  const { t } = useI18n(contentHealthMessages);
  const displayed = presentContentHealthIssue(issue, t);
  return <>
    <span className="repository-content-health-issue-header">
      <span className={`repository-content-health-severity ${issue.severity}`}>{severityLabel(issue.severity)}</span>
      <strong>{displayed.title}</strong>
    </span>
    <span className="repository-content-health-issue-message">{displayed.message}</span>
    <span className="repository-content-health-issue-meta">
      <code>{issue.relativePath ? `${issue.relativePath}${issue.line ? `:${issue.line}` : ""}` : t("扫描级问题")}</code>
      <span>{sourceLabel(issue.source, t)}</span>
      <span>{canOpen ? t("打开并定位") : t("不可定位")}</span>
      <span>{issue.code}</span>
    </span>
  </>;
}

export function filterRepositoryContentHealthIssues(
  issues: RepositoryContentHealthIssue[],
  severity: ContentHealthSeverityFilter,
  query: string,
): RepositoryContentHealthIssue[] {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  return issues.filter((issue) => {
    if (severity !== "all" && issue.severity !== severity) return false;
    if (!normalizedQuery) return true;
    const searchable = [
      issue.title,
      issue.message,
      issue.relativePath ?? "",
      issue.code,
      String(issue.source),
    ].join("\n").toLocaleLowerCase();
    return searchable.includes(normalizedQuery);
  });
}

export function formatContentHealthBytes(value: number, locale = "zh-CN"): string {
  const bytes = Number.isFinite(value) ? Math.max(0, value) : 0;
  if (bytes < 1_024) return `${Math.round(bytes)} B`;
  if (bytes < 1_024 * 1_024) return `${(bytes / 1_024).toLocaleString(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1, useGrouping: false })} KiB`;
  return `${(bytes / (1_024 * 1_024)).toLocaleString(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1, useGrouping: false })} MiB`;
}

export function formatContentHealthCount(value: number, locale = "zh-CN"): string {
  return new Intl.NumberFormat(locale).format(Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0);
}

function severityLabel(value: RepositoryContentHealthIssue["severity"]): string {
  return value === "error" ? "Error" : "Warning";
}

function sourceLabel(value: RepositoryContentHealthIssue["source"], t: UiTranslator): string {
  if (value === "editor") return t("当前文稿内存内容");
  if (value === "disk") return t("仓库快照");
  if (value === "scan") return t("扫描状态");
  return String(value);
}

function normalizedRepositoryPath(value: string): string {
  return value.replace(/\\/g, "/").replace(/^\.\//, "").replace(/^\/+/, "");
}

interface ContentHealthWorkerResponse {
  requestId: number;
  report?: RepositoryContentHealthReport;
  error?: string;
  errorSource?: "local";
}

class ContentHealthUiError extends Error {
  constructor(readonly presentation: UiMessage) { super(presentation.source); }
}

function scanError(error: unknown): UiMessage {
  const detail = error instanceof ContentHealthUiError ? error.presentation : messageFrom(error);
  return typeof detail === "string"
    ? { source: "无法扫描仓库内容：{error}", parameters: { error: detail } }
    : { source: "无法扫描仓库内容：{error}", labels: { error: detail } };
}

/** Only descriptors that reproduce the saved source may change its display. */
export function presentContentHealthIssue(issue: RepositoryContentHealthIssue, t: UiTranslator) {
  if (!issue.presentation) return { title: issue.title, message: issue.message };
  const original = presentDiagnostic(issue, createUiTranslator("zh-CN"));
  const displayed = presentDiagnostic(issue, t);
  return { title: original.title === issue.title ? displayed.title : issue.title, message: original.message === issue.message ? displayed.message : issue.message };
}

function analyzeRepositoryContentHealthOffMainThread(
  snapshot: ContentHealthSourceSnapshot,
  overlay: EditorOverlay,
  requestId: number,
  taskRef: { current: ContentHealthAnalysisTask | null },
): Promise<RepositoryContentHealthReport> {
  if (typeof Worker === "undefined") {
    return Promise.reject(new ContentHealthUiError({ source: "当前运行环境不支持后台内容分析；未执行分析。" }));
  }

  return new Promise((resolve, reject) => {
    let worker: Worker;
    try {
      worker = new Worker(
        new URL("../features/health/repositoryContentHealth.worker.ts", import.meta.url),
        { type: "module" },
      );
    } catch {
      reject(new ContentHealthUiError({ source: "无法启动后台内容分析；未执行分析。" }));
      return;
    }

    let settled = false;
    let task: ContentHealthAnalysisTask;
    const finish = () => {
      if (settled) return false;
      settled = true;
      worker.terminate();
      if (taskRef.current === task) taskRef.current = null;
      return true;
    };
    task = {
      cancel: () => {
        if (!finish()) return;
        reject(new ContentHealthUiError({ source: "内容健康分析已取消。" }));
      },
    };
    taskRef.current = task;
    worker.onmessage = (event: MessageEvent<ContentHealthWorkerResponse>) => {
      if (event.data.requestId !== requestId || !finish()) return;
      if (event.data.report) resolve(event.data.report);
      else if (!event.data.error || (event.data.errorSource === "local" && event.data.error === "内容健康分析失败。")) reject(new ContentHealthUiError({ source: "内容健康分析失败。" }));
      else reject(new Error(event.data.error));
    };
    worker.onerror = () => {
      if (!finish()) return;
      reject(new ContentHealthUiError({ source: "内容健康分析工作线程失败。" }));
    };
    try {
      worker.postMessage({ requestId, snapshot, overlay: overlay ?? undefined });
    } catch {
      if (finish()) reject(new ContentHealthUiError({ source: "无法向后台内容分析发送仓库快照；未执行分析。" }));
    }
  });
}

function messageFrom(error: unknown): string | UiMessage {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null && "message" in error && typeof error.message === "string") {
    return error.message;
  }
  return typeof error === "string" ? error : { source: "未知错误" };
}
