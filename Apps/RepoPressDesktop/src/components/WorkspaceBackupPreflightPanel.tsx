import { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n/i18n";
import { backupPreflightMessages } from "../i18n/backupPreflightMessages";
import {
  WORKSPACE_BACKUP_EXCLUSIONS,
  WORKSPACE_BACKUP_SOURCES,
  type WorkspaceBackupGateway,
  type WorkspaceBackupIssue,
  type WorkspaceBackupReport,
  type WorkspaceBackupRecheck,
  type WorkspaceBackupSource,
  type WorkspaceBackupSourceInventory,
} from "../contracts/workspaceBackup";

export interface WorkspaceBackupPreflightPanelProps {
  gateway: WorkspaceBackupGateway;
  enabled: boolean;
  disabled?: boolean;
  /** Compatibility invalidation token for hosts that refresh settings externally. */
  refreshKey?: number;
}

const MAX_TIME = 8.64e15;
const TTL_MS = 300000;
const sourceLabels: Record<WorkspaceBackupSource, string> = {
  knowledge: "知识库", rss: "RSS", generalDrafts: "普通草稿", draftHistory: "草稿历史",
  workspace: "工作区", siteProfiles: "站点配置", aiProfiles: "AI 配置",
};
const statusLabels = {
  metadataOnly: "仅文件元数据",
  notFound: "未发现持久文件（不代表应用数据为空）",
  unavailable: "不可用（计数未知）",
  limited: "部分（下限，计数不完整）",
} as const;
const issueLabels: Record<WorkspaceBackupIssue, string> = {
  unsafeEntry: "发现不安全条目", readFailed: "读取失败", entryLimit: "条目数量达到上限",
  byteLimit: "字节数达到上限", timeLimit: "检查时间达到上限", unknownEntries: "存在未知条目",
  primaryMissing: "主文件未发现", changedDuringRead: "读取期间发生变化", storageUnavailable: "存储不可用",
};
const exclusionLabels: Record<(typeof WORKSPACE_BACKUP_EXCLUSIONS)[number], string> = {
  credentials: "凭据（Secret Service，不查询）", encryptedChat: "加密聊天内容",
  releaseLedgers: "发布台账（P40 独立处理）", operationLogs: "操作日志", repositoryFiles: "仓库文件",
  externalAttachments: "外部附件", runtimeState: "运行时状态", unknownLocations: "未知位置",
};
const issueSet = new Set<string>(Object.keys(issueLabels));
const sourceSet = new Set<string>(WORKSPACE_BACKUP_SOURCES);
const exclusionSet = new Set<string>(WORKSPACE_BACKUP_EXCLUSIONS);
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const time = (value: unknown): value is number => safeInt(value) && value > 0 && value <= MAX_TIME;
const sourceOrder = (values: readonly WorkspaceBackupSource[]) => values.map((value) => WORKSPACE_BACKUP_SOURCES.indexOf(value));
const sortedUniqueSources = (values: unknown): values is WorkspaceBackupSource[] => Array.isArray(values)
  && values.length <= WORKSPACE_BACKUP_SOURCES.length && values.every((value) => typeof value === "string" && sourceSet.has(value))
  && new Set(values).size === values.length && sourceOrder(values as WorkspaceBackupSource[]).every((value, index, all) => index === 0 || value > all[index - 1]);
const sortedIssues = (values: unknown): values is WorkspaceBackupIssue[] => Array.isArray(values)
  && values.length <= 9 && new Set(values).size === values.length && values.every((value) => typeof value === "string" && issueSet.has(value));
const sameSources = (a: readonly WorkspaceBackupSource[], b: readonly WorkspaceBackupSource[]) => a.length === b.length && a.every((value, index) => value === b[index]);
const now = () => Date.now();

function validInventory(value: unknown): value is WorkspaceBackupSourceInventory {
  if (!value || typeof value !== "object") return false;
  const item = value as WorkspaceBackupSourceInventory;
  if (!sourceSet.has(item.source) || !sortedIssues(item.issues) || item.requiresDatabaseSnapshot !== ["rss", "generalDrafts", "draftHistory"].includes(item.source)) return false;
  const count = (candidate: unknown, max: number) => candidate === null || (safeInt(candidate) && candidate >= 0 && candidate <= max);
  if (item.status === "unavailable") return item.fileCount === null && item.byteCount === null && item.omittedEntries === null && item.issues.length > 0;
  if (item.status === "notFound") return item.fileCount === 0 && item.byteCount === 0 && item.omittedEntries === 0 && item.issues.length === 0;
  if (item.fileCount === null || item.byteCount === null || item.omittedEntries === null
    || !count(item.fileCount, 2048) || !count(item.byteCount, 8 * 1024 * 1024 * 1024) || !count(item.omittedEntries, 2049)) return false;
  if (item.status === "metadataOnly") return item.fileCount > 0 && item.omittedEntries === 0 && item.issues.length === 0;
  return item.status === "limited" && item.fileCount !== null && item.byteCount !== null && item.omittedEntries !== null
    && item.fileCount + item.omittedEntries <= 2049 && item.issues.length > 0;
}

function validReport(value: unknown, selected?: readonly WorkspaceBackupSource[]): value is WorkspaceBackupReport {
  if (!value || typeof value !== "object") return false;
  const report = value as WorkspaceBackupReport;
  if (!uuid(report.reportId) || report.schemaVersion !== 1 || report.scope !== "applicationPrivateData"
    || !time(report.checkedAtEpochMs) || !time(report.expiresAtEpochMs) || report.checkedAtEpochMs > now()
    || report.expiresAtEpochMs <= now() || report.expiresAtEpochMs - report.checkedAtEpochMs !== TTL_MS
    || !sortedUniqueSources(report.selectedSources) || (selected && !sameSources(report.selectedSources, selected))
    || !Array.isArray(report.sources) || report.sources.length !== report.selectedSources.length
    || new Set(report.sources.map((item) => item && typeof item === "object" ? (item as { source?: unknown }).source : null)).size !== report.sources.length
    || report.sources.some((item, index) => !validInventory(item) || item.source !== report.selectedSources[index])
    || !Array.isArray(report.exclusions) || report.exclusions.length !== WORKSPACE_BACKUP_EXCLUSIONS.length
    || new Set(report.exclusions).size !== WORKSPACE_BACKUP_EXCLUSIONS.length || report.exclusions.some((item) => typeof item !== "string" || !exclusionSet.has(item))
    || report.contentVerified !== false || report.consistentSnapshot !== false) return false;
  if (!WORKSPACE_BACKUP_EXCLUSIONS.every((item) => report.exclusions.includes(item))) return false;
  const knownFileCount = report.sources.reduce((sum, item) => sum + (item.fileCount ?? 0), 0);
  const knownByteCount = report.sources.reduce((sum, item) => sum + (item.byteCount ?? 0), 0);
  return knownFileCount <= 8192 && knownByteCount <= 8 * 1024 * 1024 * 1024;
}

function partial(report: WorkspaceBackupReport) { return report.sources.some((item) => item.status === "limited" || item.status === "unavailable"); }

export function WorkspaceBackupPreflightPanel({ gateway, enabled, disabled = false, refreshKey }: WorkspaceBackupPreflightPanelProps) {
  const { locale, t } = useI18n(backupPreflightMessages);
  const [selected, setSelected] = useState<WorkspaceBackupSource[]>([...WORKSPACE_BACKUP_SOURCES]);
  const [report, setReport] = useState<WorkspaceBackupReport | null>(null);
  const [busy, setBusy] = useState<"inspect" | "recheck" | null>(null);
  const [comparison, setComparison] = useState<WorkspaceBackupRecheck["comparison"] | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const generation = useRef(0);
  const busyRef = useRef(false);
  const reportRef = useRef<WorkspaceBackupReport | null>(null);
  const contextRef = useRef({ gateway, enabled, disabled, selected, refreshKey });
  contextRef.current = { gateway, enabled, disabled, selected, refreshKey };
  const reportBindingRef = useRef<{ report: WorkspaceBackupReport; context: typeof contextRef.current } | null>(null);
  const usable = enabled && !disabled;
  const issueSeparator = locale === "zh-CN" ? "、" : ", ";
  const exclusionSeparator = locale === "zh-CN" ? "；" : ", ";
  const sameContext = (candidate: typeof contextRef.current) => contextRef.current.gateway === candidate.gateway
    && contextRef.current.enabled === candidate.enabled && contextRef.current.disabled === candidate.disabled
    && contextRef.current.refreshKey === candidate.refreshKey && sameSources(contextRef.current.selected, candidate.selected);
  const discard = (candidate: WorkspaceBackupReport | null, boundGateway = gateway) => { if (candidate) void boundGateway.discardWorkspaceBackup(candidate.reportId).catch(() => undefined); };
  const currentReport = report && reportBindingRef.current?.report === report && sameContext(reportBindingRef.current.context) ? report : null;

  useEffect(() => {
    const old = reportRef.current; const oldBinding = reportBindingRef.current; reportRef.current = null; reportBindingRef.current = null; discard(old, oldBinding?.context.gateway); generation.current += 1; busyRef.current = false;
    setReport(null); setComparison(null); setBusy(null); setError(""); setMessage("");
    return () => { const current = reportRef.current; const binding = reportBindingRef.current; reportRef.current = null; reportBindingRef.current = null; discard(current, binding?.context.gateway); generation.current += 1; busyRef.current = false; };
  }, [gateway, enabled, disabled, refreshKey]);

  useEffect(() => {
    if (!report) return;
    const timer = window.setTimeout(() => { if (reportRef.current !== report) return; const binding = reportBindingRef.current; reportRef.current = null; reportBindingRef.current = null; discard(report, binding?.context.gateway); setReport(null); setComparison(null); setError("清单已过期，请重新检查备份范围。"); }, Math.max(0, report.expiresAtEpochMs - now()));
    return () => window.clearTimeout(timer);
  }, [report?.reportId, report?.expiresAtEpochMs]);

  function changeSource(source: WorkspaceBackupSource, checked: boolean) {
    if (busyRef.current) return;
    const next = WORKSPACE_BACKUP_SOURCES.filter((item) => item === source ? checked : selected.includes(item));
    const old = reportRef.current; const oldBinding = reportBindingRef.current; reportRef.current = null; reportBindingRef.current = null; discard(old, oldBinding?.context.gateway); generation.current += 1;
    setSelected(next); setReport(null); setComparison(null); setError(""); setMessage("");
  }

  async function inspect() {
    if (!usable || busyRef.current) return;
    const requestContext = contextRef.current; const request = ++generation.current; busyRef.current = true; setBusy("inspect"); setError(""); setMessage(""); setComparison(null);
    try {
      const next: unknown = await gateway.inspectWorkspaceBackup([...selected]);
      if (request !== generation.current || !sameContext(requestContext)) {
        if (validReport(next, requestContext.selected)) discard(next, requestContext.gateway);
        return;
      }
      if (!validReport(next, requestContext.selected)) throw new Error("invalid");
      reportRef.current = next; reportBindingRef.current = { report: next, context: requestContext }; setReport(next);
    } catch { if (request === generation.current && sameContext(requestContext)) setError("无法检查备份范围，请稍后重试。"); }
    finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } }
  }

  async function recheck() {
    const old = currentReport; const requestContext = contextRef.current;
    if (!usable || busyRef.current || !old || !sameContext(requestContext) || reportBindingRef.current?.report !== old || !sameContext(reportBindingRef.current.context)) return;
    if (old.expiresAtEpochMs <= now()) { const binding = reportBindingRef.current; reportRef.current = null; reportBindingRef.current = null; setReport(null); setComparison(null); discard(old, binding?.context.gateway); setError("清单已过期，请重新检查备份范围。"); return; }
    reportRef.current = null; setReport(null); setComparison(null); setBusy("recheck"); setError(""); setMessage(""); busyRef.current = true;
    const request = ++generation.current;
    try {
      const next: unknown = await gateway.recheckWorkspaceBackup(old.reportId);
      if (request !== generation.current || !sameContext(requestContext)) { if (next && typeof next === "object" && validReport((next as WorkspaceBackupRecheck).report)) discard((next as WorkspaceBackupRecheck).report, requestContext.gateway); return; }
      if (!next || typeof next !== "object" || !validReport((next as WorkspaceBackupRecheck).report, requestContext.selected)
        || !["unchanged", "changed", "inconclusive"].includes((next as WorkspaceBackupRecheck).comparison)
        || (next as WorkspaceBackupRecheck).report.reportId === old.reportId
        ) throw new Error("invalid");
      const result = next as WorkspaceBackupRecheck;
      const safeComparison = partial(old) || partial(result.report) ? "inconclusive" : result.comparison;
      reportRef.current = result.report; reportBindingRef.current = { report: result.report, context: requestContext }; setReport(result.report); setComparison(safeComparison); setMessage("已重新核对清单；这仍是文件元数据，不验证内容，不保证正文一致或可恢复。");
    } catch { if (request === generation.current && sameContext(requestContext)) setError("重新核对失败；旧清单已消耗，请重新检查备份范围。"); }
    finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } }
  }

  return <section className="operation-plan" aria-label={t("工作区备份预检")} aria-busy={busy !== null}>
    <h4>{t("工作区备份预检")}</h4>
    <p className="publish-muted">{t("只读取应用私有数据的持久文件元数据；不会读取正文，不验证内容，不提供导出、恢复或删除权限。初始选择已全选，必须明确点击检查。")}</p>
    <div>{WORKSPACE_BACKUP_SOURCES.map((source) => <label key={source} style={{ display: "block" }}><input type="checkbox" checked={selected.includes(source)} onChange={(event) => changeSource(source, event.target.checked)} disabled={!usable || busy !== null} />{t(sourceLabels[source])}</label>)}</div>
    <button type="button" onClick={() => void inspect()} disabled={!usable || busy !== null}>{t("检查备份范围")}</button>
    {busy === "inspect" && <p role="status" className="publish-muted">{t("正在检查所选备份范围…")}</p>}
    {busy === "recheck" && <p role="status" className="publish-muted">{t("正在重新核对清单…")}</p>}
    {error && <p role="alert" className="publish-warning">{t(error)}</p>}{message && <p role="status">{t(message)}</p>}
    {currentReport && <div className="operation-plan"><p><strong>{t("清单 ID（仅元数据标识，不是执行授权）")}</strong>{t("：{reportId}", { reportId: currentReport.reportId })}</p><p>{t("检查时间：{checkedAt}；有效至：{expiresAt}", { checkedAt: new Date(currentReport.checkedAtEpochMs).toLocaleString(locale), expiresAt: new Date(currentReport.expiresAtEpochMs).toLocaleString(locale) })}</p><p>{t("未验证正文或文件内容；未生成一致的数据库快照，清单不代表可恢复备份。")}</p>{comparison && <p role="status">{t("重新核对结果：{comparison}", { comparison: t(comparison === "unchanged" ? "状态未变化" : comparison === "changed" ? "状态已变化" : "无法确定（存在部分清单）") })}</p>}
      {currentReport.sources.map((item) => <article key={item.source}><h5>{t(sourceLabels[item.source])}</h5><p>{t("状态：{status}", { status: t(statusLabels[item.status]) })}</p><dl><dt>{t("物理文件数")}</dt><dd>{item.fileCount === null ? t("未知") : item.fileCount.toLocaleString(locale)}</dd><dt>{t("字节数")}</dt><dd>{item.byteCount === null ? t("未知") : item.byteCount.toLocaleString(locale)}</dd><dt>{t(item.status === "limited" ? "已发现至少省略条目" : "已发现省略条目")}</dt><dd>{item.omittedEntries === null ? t("未知") : item.omittedEntries.toLocaleString(locale)}</dd></dl>{item.issues.length > 0 && <p className="publish-warning">{t("问题：{issues}", { issues: item.issues.map((issue) => t(issueLabels[issue])).join(issueSeparator) })}</p>}{item.requiresDatabaseSnapshot && <p className="publish-warning">{t("SQLite 数据库：后续备份必须使用一致性快照，不能直接复制数据库与日志文件。")}</p>}</article>)}
      <p><strong>{t("固定排除项")}</strong>{t("：{items}", { items: currentReport.exclusions.map((item) => t(exclusionLabels[item])).join(exclusionSeparator) })}</p>
      {currentReport.selectedSources.some((item) => ["knowledge", "rss", "generalDrafts", "draftHistory"].includes(item)) && <p className="publish-warning">{t("知识库、RSS、草稿及草稿历史可能包含正文、URL 和路径。")}</p>}
      {currentReport.selectedSources.includes("workspace") && <p className="publish-warning">{t("工作区状态可能包含恢复正文和路径。")}</p>}
      {currentReport.selectedSources.some((item) => ["siteProfiles", "aiProfiles"].includes(item)) && <p className="publish-warning">{t("配置可能包含路径、端点和带秘密的 URL。")}</p>}
      <button type="button" onClick={() => void recheck()} disabled={busy !== null}>{t("重新核对清单（重新检查）")}</button>
    </div>}
  </section>;
}
