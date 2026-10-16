import { renderUiMessage, type UiMessage, type UiTemplate } from "../i18n/uiMessage";
import { useI18n, type UiTranslator } from "../i18n/i18n";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import type { RepositoryGateway } from "../contracts/repository";
import type { UnpublishImpactFinding, UnpublishImpactReport, UnpublishImpactTarget } from "../contracts/unpublishImpact";
import { sameUnpublishImpactSources } from "../features/publish/unpublishImpactSnapshot";
import { startUnpublishImpactAnalysis, UnpublishImpactAnalysisError, type UnpublishImpactAnalysisTask } from "../features/publish/unpublishImpactAnalysis";
import "./RepositoryContentHealthPanel.css";

type ScanState = "idle" | "loading" | "success" | "error";
type StatusFilter = "all" | UnpublishImpactFinding["status"];
const MAX_RENDERED_FINDINGS = 100;

export interface UnpublishImpactPanelProps {
  enabled: boolean;
  sessionId: string | null;
  gateway: Pick<RepositoryGateway, "inspectContentHealthSources">;
  currentDocument: UnpublishImpactTarget | null;
  onLocateIssue?: (path: string, range: { from: number; to: number }, expectedText: string) => void;
}

export function UnpublishImpactPanel({ enabled, sessionId, gateway, currentDocument, onLocateIssue }: UnpublishImpactPanelProps) {
  const { t } = useI18n();
  const [report, setReport] = useState<UnpublishImpactReport | null>(null);
  const [snapshot, setSnapshot] = useState<Awaited<ReturnType<RepositoryGateway["inspectContentHealthSources"]>> | null>(null);
  const [capturedTarget, setCapturedTarget] = useState<UnpublishImpactTarget | null>(null);
  const [state, setState] = useState<ScanState>("idle");
  const [error, setError] = useState<UiMessage | null>(null);
  const [filter, setFilter] = useState<StatusFilter>("all");
  const [revalidation, setRevalidation] = useState<string | null>(null);
  const [rechecking, setRechecking] = useState(false);
  const [page, setPage] = useState(0);
  const generation = useRef(0);
  const task = useRef<UnpublishImpactAnalysisTask | null>(null);
  const busy = useRef(false);
  const id = useId();

  useEffect(() => {
    generation.current += 1;
    task.current?.cancel(); task.current = null; busy.current = false;
    setReport(null); setSnapshot(null); setCapturedTarget(null); setState("idle"); setError(null); setFilter("all"); setRevalidation(null); setRechecking(false); setPage(0);
    return () => { generation.current += 1; task.current?.cancel(); task.current = null; busy.current = false; };
  }, [enabled, sessionId, gateway, currentDocument?.relativePath, currentDocument?.text]);

  const sourceText = useMemo(() => {
    const map = new Map<string, string>();
    for (const document of snapshot?.documents ?? []) map.set(normalize(document.relativePath), document.text);
    return map;
  }, [snapshot]);
  const findings = useMemo(() => (report?.findings ?? []).filter((item) => filter === "all" || item.status === filter), [filter, report]);

  async function scan() {
    if (!enabled || !sessionId || !currentDocument || busy.current) return;
    busy.current = true;
    const requestedSession = sessionId;
    const requestedTarget = { ...currentDocument };
    const current = ++generation.current;
    setState("loading"); setError(null); setReport(null); setSnapshot(null); setCapturedTarget(null); setRevalidation(null); setPage(0);
    try {
      const nextSnapshot = await gateway.inspectContentHealthSources(requestedSession);
      if (current !== generation.current) return;
      const nextTask = startUnpublishImpactAnalysis({ sources: nextSnapshot, target: requestedTarget });
      task.current = nextTask;
      const nextReport = await nextTask.promise;
      if (current !== generation.current) return;
      setSnapshot(nextSnapshot); setCapturedTarget(requestedTarget); setReport(nextReport); setState("success");
    } catch (cause) {
      if (current !== generation.current) return;
      setState("error"); setError({ source: "{error}", ...messageFrom(cause) });
    } finally {
      if (current === generation.current) { task.current = null; busy.current = false; }
    }
  }

  async function recheckSources() {
    if (!enabled || !sessionId || !snapshot || !report || !report.targetAvailable || busy.current) return;
    busy.current = true; const current = ++generation.current; const requestedTarget = currentDocument ? { ...currentDocument } : null;
    setRechecking(true); setRevalidation(null); setError(null);
    try {
      const next = await gateway.inspectContentHealthSources(sessionId);
      if (current !== generation.current) return;
      const targetSame = Boolean(requestedTarget && capturedTarget && requestedTarget.relativePath === capturedTarget.relativePath && requestedTarget.text === capturedTarget.text);
      if (!sameUnpublishImpactSources(snapshot, next) || !targetSame) {
        setReport(null); setSnapshot(null); setCapturedTarget(null); setState("idle");
        setRevalidation("来源或当前文稿已变化，原报告已失效。请重新扫描。");
      } else setRevalidation("本次核对时来源快照未变化；这不保证未来状态或报告完整性。");
    } catch (cause) {
      if (current === generation.current) {
        setReport(null); setSnapshot(null); setCapturedTarget(null); setState("idle");
        const detail = messageFrom(cause);
        setError({ source: "无法重新核对来源：{error}；原报告已失效，请重新扫描。", ...detail });
      }
    } finally { if (current === generation.current) { busy.current = false; setRechecking(false); } }
  }

  if (!enabled) return <section className="advanced-panel" aria-label={t("文章下线影响审阅")}><strong>{t("文章下线影响审阅")}</strong><p className="tool-muted">{t("当前运行环境未提供本地来源扫描；不会读取仓库。")}</p></section>;
  return <section className="advanced-panel unpublish-impact-panel" aria-label={t("文章下线影响审阅")} aria-busy={state === "loading" || rechecking}>
    <div className="advanced-heading"><div><strong>{t("文章下线影响审阅")}</strong><p>{t("仅扫描本地快照，分析只读、不联网、不写盘；不会执行下线。")}</p></div><div className="repository-content-health-badges"><span className="tool-badge">{t("本地")}</span><span className="tool-badge">{t("只读")}</span></div></div>
    <div className="tool-actions"><button type="button" onClick={() => void scan()} disabled={!sessionId || !currentDocument || state === "loading" || rechecking}>{state === "loading" ? t("正在扫描…") : state === "error" ? t("重试扫描") : t("扫描下线影响")}</button>{report && <button type="button" onClick={() => void recheckSources()} disabled={state === "loading" || rechecking || !report.targetAvailable}>{t("重新核对来源")}</button>}</div>
    {!sessionId && <p className="tool-muted">{t("请先打开本地仓库；不会自动扫描。")}</p>}
    {!currentDocument && <p className="tool-muted">{t("当前没有打开的文章，无法建立下线目标快照。")}</p>}
    {state === "idle" && sessionId && currentDocument && <p className="tool-muted">{t("尚未扫描。点击按钮后才会读取仓库来源。")}</p>}
    {state === "loading" && <p className="tool-state" role="status">{t("正在本地读取并分析来源…")}</p>}
    {rechecking && <p className="tool-state" role="status">{t("正在重新核对来源…")}</p>}
    {error && <p className="tool-error" role="alert">{renderUiMessage(error, t)}</p>}
    {revalidation && <p className="tool-warning" role="status">{t(revalidation)}</p>}
    {report && snapshot && <ImpactResults report={report} findings={findings} filter={filter} setFilter={(value) => { setFilter(value); setPage(0); }} page={page} setPage={setPage} locatingDisabled={rechecking} sourceText={sourceText} onLocateIssue={onLocateIssue} id={id} />}
  </section>;
}

function ImpactResults({ report, findings, filter, setFilter, page, setPage, locatingDisabled, sourceText, onLocateIssue, id }: { report: UnpublishImpactReport; findings: UnpublishImpactFinding[]; filter: StatusFilter; setFilter: (filter: StatusFilter) => void; page: number; setPage: (page: number) => void; locatingDisabled: boolean; sourceText: ReadonlyMap<string, string>; onLocateIssue?: UnpublishImpactPanelProps["onLocateIssue"]; id: string }) {
  const { t } = useI18n();
  const counts = { confirmed: report.findings.filter((x) => x.status === "confirmed").length, possible: report.findings.filter((x) => x.status === "possible").length, unresolved: report.findings.filter((x) => x.status === "unresolved").length };
  const incomplete = report.partial || report.truncated || report.omittedDocuments > 0;
  return <>
    <section className="tool-subsection" aria-labelledby={`${id}-summary`}><h2 id={`${id}-summary`}>{t("扫描结果")}</h2><p><strong>{t("目标")}</strong> <code>{report.targetPath}</code></p><p><strong>{t("确认源文件引用")}</strong> {counts.confirmed} · <strong>{t("可能的网站引用")}</strong> {counts.possible} · <strong>{t("未解析链接")}</strong> {counts.unresolved}</p><p className="tool-muted">{t("已扫描 {count} 个文档；结果最多保留 2000 条，每页显示 {limit} 条。未解析链接不代表已知影响。", { count: report.scannedDocuments, limit: MAX_RENDERED_FINDINGS })}</p><p className="tool-muted">{t("遗漏文档 {omitted} · 绝对网址/外链 {external}。未解析模板、重定向和网站生成规则。", { omitted: report.omittedDocuments, external: report.externalLinks })}</p>{!report.targetAvailable && <p className="tool-warning" role="alert">{t("目标文章未包含在本次快照中，无法重新核验目标状态。")}</p>}{report.targetEdited && <p className="tool-warning">{t("报告使用扫描开始时编辑器内存中的目标内容；继续编辑后请重新扫描。")}</p>}{incomplete && <p className="tool-warning" role="alert">{t("结果不完整：存在截断、遗漏或未扫描文档，零命中也不能视为可以安全删除。")}</p>}{report.warnings.map((warning, index) => <p className="tool-warning" key={`${index}:${warning}`}>{analysisText(warning, report.warningPresentations?.[index], t)}</p>)}</section>
    <section aria-labelledby={`${id}-findings`}><div className="repository-content-health-findings-heading"><h2 id={`${id}-findings`}>{t("引用列表")}</h2><span>{findings.length} / {report.findings.length}</span></div><label htmlFor={`${id}-filter`}>{t("筛选")}</label><select id={`${id}-filter`} value={filter} onChange={(event) => setFilter(event.target.value as StatusFilter)}><option value="all">{t("全部")}</option><option value="confirmed">{t("确认源文件引用")}</option><option value="possible">{t("可能的网站引用")}</option><option value="unresolved">{t("未解析链接")}</option></select>{findings.length === 0 ? <p role="status">{t("本次扫描范围没有可显示的引用；这不是安全删除保证。")}</p> : <><ol>{findings.slice(page * MAX_RENDERED_FINDINGS, (page + 1) * MAX_RENDERED_FINDINGS).map((finding) => { const expected = sourceText.get(normalize(finding.documentPath)); const canLocate = expected !== undefined && Boolean(onLocateIssue); return <li key={finding.id}><span><strong>{t(statusLabel(finding.status))}</strong> <code>{finding.documentPath}:{finding.line}</code> <code>{finding.target}</code></span><p>{analysisText(finding.reason, finding.reasonPresentation, t)}</p>{canLocate && <button type="button" disabled={locatingDisabled} aria-label={t("打开并定位 {path} 第 {line} 行", { path: finding.documentPath, line: finding.line })} onClick={() => onLocateIssue?.(finding.documentPath, finding.range, expected!)}>{t("打开并定位")}</button>}</li>; })}</ol><div role="navigation" aria-label={t("引用结果分页")}><button type="button" disabled={page === 0 || locatingDisabled} onClick={() => setPage(page - 1)}>{t("上一页")}</button><span>{t("第 {page} / {pages} 页", { page: page + 1, pages: Math.max(1, Math.ceil(findings.length / MAX_RENDERED_FINDINGS)) })}</span><button type="button" disabled={(page + 1) * MAX_RENDERED_FINDINGS >= findings.length || locatingDisabled} onClick={() => setPage(page + 1)}>{t("下一页")}</button></div></>}</section>
  </>;
}

function normalize(value: string) { return value.replace(/\\/g, "/").replace(/^\.\//, "").replace(/^\/+/, ""); }
function analysisText(raw: string, presentation: UiTemplate | undefined, t: UiTranslator): string {
  return presentation?.source === raw && presentation.parameters === undefined ? t(presentation.source) : raw;
}
function statusLabel(status: UnpublishImpactFinding["status"]) { return status === "confirmed" ? "确认源文件引用" : status === "possible" ? "可能的网站引用" : "未解析链接"; }
function messageFrom(error: unknown): Pick<UiMessage, "labels" | "parameters"> {
  if (error instanceof UnpublishImpactAnalysisError) return { labels: { error: error.presentation } };
  const raw = error instanceof Error ? error.message : typeof error === "string" ? error : null;
  return raw === null ? { labels: { error: { source: "未知错误" } } } : { parameters: { error: raw } };
}
