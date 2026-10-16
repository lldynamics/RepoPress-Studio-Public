import { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n/i18n";
import { backupPreflightMessages } from "../i18n/backupPreflightMessages";
import {
  KNOWLEDGE_INTEGRITY_EXCLUSIONS,
  KNOWLEDGE_INTEGRITY_ISSUES,
  KNOWLEDGE_INTEGRITY_LIMITS,
  type KnowledgeIntegrityGateway,
  type KnowledgeIntegrityIssue,
  type KnowledgeIntegrityReport,
  type KnowledgeIntegrityRecheck,
  type KnowledgeIntegrityResourceSummary,
} from "../contracts/knowledgeIntegrity";

export interface KnowledgeIntegrityPanelProps {
  gateway: KnowledgeIntegrityGateway;
  enabled: boolean;
  disabled?: boolean;
  /** Compatibility invalidation token for hosts that refresh settings externally. */
  refreshKey?: number;
}

const TTL_MS = 300000;
const MAX_TIME = 8.64e15;
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const safeInt = (value: unknown, max = Number.MAX_SAFE_INTEGER): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= max;
const validTime = (value: unknown): value is number => safeInt(value, MAX_TIME) && value > 0;
const issueSet = new Set<string>(KNOWLEDGE_INTEGRITY_ISSUES);
const exclusionSet = new Set<string>(KNOWLEDGE_INTEGRITY_EXCLUSIONS);
const issueLabels: Record<KnowledgeIntegrityIssue, string> = {
  manifestMissing: "资料清单缺失", manifestUnsafe: "资料清单不安全", manifestUnreadable: "资料清单不可读", manifestTooLarge: "资料清单过大", manifestInvalid: "资料清单无效", unsupportedVersion: "资料清单版本不支持", unsafeDirectory: "引用目录不安全", missingFile: "引用文件缺失", unsafeFile: "引用文件不安全", readFailed: "引用读取失败", invalidContent: "引用内容无效", changedDuringRead: "读取期间发生变化", fileLimit: "达到文件数量上限", byteLimit: "达到字节数上限", timeLimit: "达到检查时间上限", incompleteArchive: "存档完整性不足", unknownArchiveCompleteness: "存档完整性未知",
};
const manifestLabels: Record<KnowledgeIntegrityReport["manifestState"], string> = {
  verified: "已验证", missing: "缺失", unsafe: "不安全", unreadable: "不可读", tooLarge: "过大", invalid: "无效", unsupported: "版本不支持", changed: "读取期间发生变化",
};
const statusLabels: Record<KnowledgeIntegrityReport["status"], string> = {
  checked: "已完成本次检查", partial: "部分结果", unavailable: "不可用",
};
const exclusionLabels: Record<(typeof KNOWLEDGE_INTEGRITY_EXCLUSIONS)[number], string> = {
  credentials: "凭据", otherWorkspaceSources: "其他工作区资料来源", repositoryFiles: "仓库文件", externalReferences: "外部引用", unreferencedFiles: "未被引用的文件", runtimeState: "运行时状态",
};
const sameContext = (a: Context, b: Context) => a.gateway === b.gateway && a.enabled === b.enabled && a.disabled === b.disabled && a.refreshKey === b.refreshKey;
type Context = { gateway: KnowledgeIntegrityGateway; enabled: boolean; disabled: boolean; refreshKey?: number };

function sortedIssues(value: unknown): value is KnowledgeIntegrityIssue[] {
  return Array.isArray(value) && value.length <= KNOWLEDGE_INTEGRITY_ISSUES.length && new Set(value).size === value.length
    && value.every((item) => typeof item === "string" && issueSet.has(item));
}
function validResource(value: unknown): value is KnowledgeIntegrityResourceSummary {
  if (!value || typeof value !== "object") return false;
  const item = value as KnowledgeIntegrityResourceSummary;
  if (item.kind !== "body" && item.kind !== "archive") return false;
  const counts = [item.referenceCount, item.uniqueFiles, item.verified, item.missing, item.unsafe, item.unreadable, item.invalid, item.changed, item.omitted];
  if (!counts.every((candidate) => safeInt(candidate, KNOWLEDGE_INTEGRITY_LIMITS.resourceFiles * 64)) || !safeInt(item.verifiedBytes, KNOWLEDGE_INTEGRITY_LIMITS.resourceBytes)) return false;
  if (item.uniqueFiles > 64000 || item.referenceCount > 64000 || item.referenceCount < item.uniqueFiles) return false;
  if (item.verified + item.missing + item.unsafe + item.unreadable + item.invalid + item.changed + item.omitted !== item.uniqueFiles) return false;
  return true;
}
function orderedResources(value: unknown): value is KnowledgeIntegrityResourceSummary[] {
  return Array.isArray(value) && value.length <= 2 && value.every(validResource)
    && new Set(value.map((item) => item.kind)).size === value.length
    && value.every((item, index) => index === 0 || value[index - 1].kind === "body" || item.kind === "archive");
}
function validReport(value: unknown): value is KnowledgeIntegrityReport {
  if (!value || typeof value !== "object") return false;
  const report = value as KnowledgeIntegrityReport;
  if (!report.limits || typeof report.limits !== "object" || !Array.isArray(report.resources)) return false;
  const validManifestState = ["verified", "missing", "unsafe", "unreadable", "tooLarge", "invalid", "unsupported", "changed"].includes(report.manifestState);
  const validManifestVersion = report.manifestSchemaVersion === null || safeInt(report.manifestSchemaVersion, 0xffffffff);
  const validManifestSha = report.manifestSha256 === null || (typeof report.manifestSha256 === "string" && /^[0-9a-f]{64}$/.test(report.manifestSha256));
  if (!uuid(report.reportId) || report.schemaVersion !== 1 || report.scope !== "applicationKnowledgeReferences"
    || !validTime(report.checkedAtEpochMs) || !validTime(report.expiresAtEpochMs) || report.checkedAtEpochMs > Date.now()
    || report.expiresAtEpochMs <= Date.now() || report.expiresAtEpochMs - report.checkedAtEpochMs !== TTL_MS
    || !sortedIssues(report.issues) || !Array.isArray(report.exclusions) || report.exclusions.length !== KNOWLEDGE_INTEGRITY_EXCLUSIONS.length
    || new Set(report.exclusions).size !== KNOWLEDGE_INTEGRITY_EXCLUSIONS.length || report.exclusions.some((item) => typeof item !== "string" || !exclusionSet.has(item))
    || !KNOWLEDGE_INTEGRITY_EXCLUSIONS.every((item, index) => report.exclusions[index] === item)
    || !validManifestState || !validManifestVersion || !validManifestSha
    || report.consistentSnapshot !== false || report.backupReady !== false || report.limits.manifestBytes !== KNOWLEDGE_INTEGRITY_LIMITS.manifestBytes
    || report.limits.resourceFiles !== KNOWLEDGE_INTEGRITY_LIMITS.resourceFiles || report.limits.resourceBytes !== KNOWLEDGE_INTEGRITY_LIMITS.resourceBytes || report.limits.durationMs !== KNOWLEDGE_INTEGRITY_LIMITS.durationMs
    || !safeInt(report.archiveMissingResources, 64000) || !safeInt(report.archiveTruncated, 64000) || !safeInt(report.archiveUnknownCompleteness, 64000)) return false;
  const verifiedManifest = report.manifestState === "verified";
  if (verifiedManifest) {
    if (!orderedResources(report.resources) || report.resources.length !== 2 || report.resources[0].kind !== "body" || report.resources[1].kind !== "archive"
      || report.manifestSchemaVersion !== 4 || report.manifestSha256 === null
      || report.itemCount === null || report.revisionCount === null || !safeInt(report.itemCount, 2000) || !safeInt(report.revisionCount, 64000)
      || report.resources[0].referenceCount !== report.revisionCount || report.resources[1].referenceCount > report.revisionCount
      || report.archiveMissingResources > report.resources[1].referenceCount || report.archiveTruncated > report.resources[1].referenceCount || report.archiveUnknownCompleteness > report.resources[1].referenceCount
      || (report.archiveMissingResources > 0 && !report.issues.includes("incompleteArchive"))
      || (report.archiveTruncated > 0 && !report.issues.includes("incompleteArchive")) || (report.archiveUnknownCompleteness > 0 && !report.issues.includes("unknownArchiveCompleteness"))) return false;
  } else if (report.resources.length !== 0 || report.itemCount !== null || report.revisionCount !== null || report.allReferencedFilesVerified
    || report.archiveMissingResources !== 0 || report.archiveTruncated !== 0 || report.archiveUnknownCompleteness !== 0 || report.issues.length === 0) return false;
  const allFiles = verifiedManifest && report.resources.every((item) => item.verified === item.uniqueFiles)
    && !report.issues.includes("changedDuringRead") && !report.issues.includes("unsafeDirectory") && !report.issues.includes("timeLimit");
  if (report.allReferencedFilesVerified !== allFiles || report.status !== (verifiedManifest ? (allFiles && report.issues.length === 0 ? "checked" : "partial") : "unavailable")) return false;
  const verifiedFiles = report.resources.reduce((sum, item) => sum + item.verified, 0);
  const verifiedBytes = report.resources.reduce((sum, item) => sum + item.verifiedBytes, 0);
  return verifiedFiles <= KNOWLEDGE_INTEGRITY_LIMITS.resourceFiles && verifiedBytes <= KNOWLEDGE_INTEGRITY_LIMITS.resourceBytes;
}
const discardId = (gateway: KnowledgeIntegrityGateway, value: unknown) => { if (value && typeof value === "object" && uuid((value as { reportId?: unknown }).reportId)) void gateway.discardKnowledgeIntegrity((value as { reportId: string }).reportId).catch(() => undefined); };

export function KnowledgeIntegrityPanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeIntegrityPanelProps) {
  const { locale, t } = useI18n(backupPreflightMessages);
  const listSeparator = locale === "zh-CN" ? "、" : ", ";
  const [report, setReport] = useState<KnowledgeIntegrityReport | null>(null);
  const [comparison, setComparison] = useState<KnowledgeIntegrityRecheck["comparison"] | null>(null);
  const [busy, setBusy] = useState<"inspect" | "recheck" | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const generation = useRef(0); const busyRef = useRef(false); const reportRef = useRef<KnowledgeIntegrityReport | null>(null);
  const contextRef = useRef<Context>({ gateway, enabled, disabled, refreshKey }); contextRef.current = { gateway, enabled, disabled, refreshKey };
  const bindingRef = useRef<{ report: KnowledgeIntegrityReport; context: Context } | null>(null);
  const usable = enabled && !disabled;
  const discard = (candidate: KnowledgeIntegrityReport | null, owner = gateway) => { if (candidate) void owner.discardKnowledgeIntegrity(candidate.reportId).catch(() => undefined); };
  const current = report && bindingRef.current?.report === report && sameContext(bindingRef.current.context, contextRef.current) ? report : null;

  useEffect(() => {
    const old = reportRef.current; const binding = bindingRef.current; reportRef.current = null; bindingRef.current = null; discard(old, binding?.context.gateway); generation.current += 1; busyRef.current = false;
    setReport(null); setComparison(null); setBusy(null); setError(""); setMessage("");
    return () => { const item = reportRef.current; const owner = bindingRef.current?.context.gateway; reportRef.current = null; bindingRef.current = null; discard(item, owner); generation.current += 1; busyRef.current = false; };
  }, [gateway, enabled, disabled, refreshKey]);
  useEffect(() => {
    if (!report) return;
    const timer = window.setTimeout(() => { if (reportRef.current !== report) return; const binding = bindingRef.current; reportRef.current = null; bindingRef.current = null; discard(report, binding?.context.gateway); setReport(null); setComparison(null); setError("资料预检报告已过期，请重新检查资料引用。"); }, Math.max(0, report.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [report?.reportId, report?.expiresAtEpochMs]);
  async function inspect() {
    if (!usable || busyRef.current) return;
    const old = reportRef.current; const binding = bindingRef.current; reportRef.current = null; bindingRef.current = null; discard(old, binding?.context.gateway); setReport(null);
    const requestContext = contextRef.current; const request = ++generation.current; busyRef.current = true; setBusy("inspect"); setError(""); setMessage(""); setComparison(null);
    try { const next: unknown = await gateway.inspectKnowledgeIntegrity(); if (request !== generation.current || !sameContext(requestContext, contextRef.current)) { discardId(requestContext.gateway, next); return; } if (!validReport(next)) { discardId(requestContext.gateway, next); throw new Error("invalid"); } reportRef.current = next; bindingRef.current = { report: next, context: requestContext }; setReport(next); }
    catch { if (request === generation.current && sameContext(requestContext, contextRef.current)) setError("无法检查资料引用，请稍后重试。"); }
    finally { if (request === generation.current && sameContext(requestContext, contextRef.current)) { busyRef.current = false; setBusy(null); } }
  }
  async function recheck() {
    const old = current; const requestContext = contextRef.current;
    if (!usable || busyRef.current || !old || reportRef.current !== old || bindingRef.current?.report !== old || !sameContext(requestContext, contextRef.current) || old.expiresAtEpochMs <= Date.now()) return;
    reportRef.current = null; bindingRef.current = null; setReport(null); setComparison(null); setBusy("recheck"); setError(""); setMessage(""); busyRef.current = true; const request = ++generation.current;
    try {
      const next: unknown = await gateway.recheckKnowledgeIntegrity(old.reportId);
      const candidate = next && typeof next === "object" ? (next as Partial<KnowledgeIntegrityRecheck>).report : next;
      if (request !== generation.current || !sameContext(requestContext, contextRef.current)) { discardId(requestContext.gateway, candidate); return; }
      const comparison = next && typeof next === "object" ? (next as Partial<KnowledgeIntegrityRecheck>).comparison : undefined;
      if (!validReport(candidate) || !["unchanged", "changed", "inconclusive"].includes(comparison as string)
        || candidate.reportId === old.reportId
        || (comparison !== "inconclusive" && (old.status !== "checked" || candidate.status !== "checked"))) {
        discardId(requestContext.gateway, candidate); throw new Error("invalid");
      }
      const result = { report: candidate, comparison: comparison as KnowledgeIntegrityRecheck["comparison"] };
      reportRef.current = result.report; bindingRef.current = { report: result.report, context: requestContext }; setReport(result.report); setComparison(result.comparison); setMessage("已重新核对资料引用；部分或不完整结果仍只表示预检状态。");
    }
    catch { if (request === generation.current && sameContext(requestContext, contextRef.current)) setError("重新核对失败；旧资料预检报告已消耗，请重新检查资料引用。"); }
    finally { if (request === generation.current && sameContext(requestContext, contextRef.current)) { busyRef.current = false; setBusy(null); } }
  }
  function cancel() { const old = reportRef.current; const binding = bindingRef.current; reportRef.current = null; bindingRef.current = null; generation.current += 1; discard(old, binding?.context.gateway); setReport(null); setComparison(null); setError(""); setMessage(""); }
  return <section className="operation-plan" aria-label={t("资料引用完整性预检")} aria-busy={busy !== null}><h4>{t("资料引用完整性预检")}</h4><p className="publish-muted">{t("只读取资料私有清单及其引用的正文、历史与存档，输出数量和问题标签；不显示标题、路径、正文或 URL，不解析或抓取外部链接，也不检查未被引用的文件。")}</p><p className="publish-muted">{t("最多检查 1024 个引用文件，正文与存档合计读取 64 MiB；资料清单上限 2 MiB，读取步骤上限 5 秒，超限内容会省略。仅支持当前资料清单版本，不自动升级。")}</p><p className="publish-warning">{t("缺失清单不等于空资料库；存档缺失、截断或完整性未知会保留为部分结果。本报告不是原子快照，也不表示备份已就绪。")}</p><button type="button" onClick={() => void inspect()} disabled={!usable || busy !== null}>{t("明确检查资料引用")}</button>{busy === "inspect" && <p role="status" className="publish-muted">{t("正在检查资料引用…")}</p>}{busy === "recheck" && <p role="status" className="publish-muted">{t("正在重新核对资料引用…")}</p>}{error && <p role="alert" className="publish-warning">{t(error)}</p>}{message && <p role="status">{t(message)}</p>}{current && <div className="operation-plan"><p>{t("清单状态：{manifest}；预检状态：{status}；有效至：{expiresAt}", { manifest: t(manifestLabels[current.manifestState]), status: t(statusLabels[current.status]), expiresAt: new Date(current.expiresAtEpochMs).toLocaleString(locale) })}</p>{current.itemCount !== null && <p>{t("资料项：{items}；修订：{revisions}", { items: current.itemCount.toLocaleString(locale), revisions: current.revisionCount?.toLocaleString(locale) ?? "" })}</p>}{current.resources.map((item) => <article key={item.kind}><h5>{t(item.kind === "body" ? "正文引用" : "存档引用")}</h5><p>{t("引用数：{referenceCount}；唯一文件：{uniqueFiles}；已验证：{verified}；缺失：{missing}；不安全：{unsafe}；不可读：{unreadable}；无效：{invalid}；变化：{changed}；省略：{omitted}；已验证字节：{verifiedBytes}", { referenceCount: item.referenceCount.toLocaleString(locale), uniqueFiles: item.uniqueFiles.toLocaleString(locale), verified: item.verified.toLocaleString(locale), missing: item.missing.toLocaleString(locale), unsafe: item.unsafe.toLocaleString(locale), unreadable: item.unreadable.toLocaleString(locale), invalid: item.invalid.toLocaleString(locale), changed: item.changed.toLocaleString(locale), omitted: item.omitted.toLocaleString(locale), verifiedBytes: item.verifiedBytes.toLocaleString(locale) })}</p></article>)}{(current.archiveMissingResources || current.archiveTruncated || current.archiveUnknownCompleteness) > 0 && <p className="publish-warning">{t("存档引用完整性：缺失 {missing}；截断 {truncated}；未知 {unknown}。", { missing: current.archiveMissingResources.toLocaleString(locale), truncated: current.archiveTruncated.toLocaleString(locale), unknown: current.archiveUnknownCompleteness.toLocaleString(locale) })}</p>}{current.issues.length > 0 && <p className="publish-warning">{t("问题：{issues}", { issues: current.issues.map((issue) => t(issueLabels[issue])).join(listSeparator) })}</p>}<p>{t("固定排除：{items}", { items: current.exclusions.map((item) => t(exclusionLabels[item])).join(listSeparator) })}</p>{comparison && <p role="status">{t("重新核对结果：{comparison}", { comparison: t(comparison === "unchanged" ? "状态未变化" : comparison === "changed" ? "状态已变化" : "无法确定（保留部分信息）") })}</p>}<button type="button" onClick={() => void recheck()} disabled={!usable || busy !== null}>{t("明确重新核对资料引用")}</button><button type="button" onClick={cancel} disabled={busy !== null}>{t("丢弃资料预检报告")}</button></div>}</section>;
}
