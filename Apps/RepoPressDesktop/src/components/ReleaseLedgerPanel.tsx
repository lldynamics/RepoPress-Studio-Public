import { useI18n } from "../i18n/i18n";
import { RollbackArchivePanel } from "./RollbackArchivePanel";
import type { RollbackArchiveGateway } from "../contracts/rollbackArchive";
import { RollbackTransactionPanel, RollbackHistoryPanel } from "./RollbackTransactionPanel";
import type { RollbackTransactionGateway } from "../contracts/rollbackTransaction";
import { useEffect, useRef, useState } from "react";
import { RollbackQualificationPanel } from "./RollbackQualificationPanel";
import { RollbackChangePreviewPanel } from "./RollbackChangePreviewPanel";
import { RollbackCandidatePanel } from "./RollbackCandidatePanel";
import type { RollbackCandidateGateway } from "../contracts/rollbackCandidate";
import type { RollbackChangePreviewGateway } from "../contracts/rollbackChangePreview";
import type { RollbackQualificationGateway } from "../contracts/rollbackQualification";
import type {
  ReleaseLedgerEntry,
  ReleaseLedgerGateway,
  ReleaseLedgerSnapshot,
  ReleaseLedgerSource,
  UnattributedDeploymentObservation,
} from "../contracts/releaseLedger";

export interface ReleaseLedgerPanelProps {
  archiveGateway?: RollbackArchiveGateway;
  gateway: ReleaseLedgerGateway;
  rollbackGateway?: RollbackQualificationGateway;
  previewGateway?: RollbackChangePreviewGateway;
  candidateGateway?: RollbackCandidateGateway;
  transactionGateway?: RollbackTransactionGateway;
  sessionId: string;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
  onOpenSource?: (source: ReleaseLedgerSource) => void;
  deployment?: UnattributedDeploymentObservation | null;
  focusRecordId?: string | null;
  focusRequest?: number;
}

const genericError = "无法读取发布台账，请稍后重试。";
const pageSize = 50;
const sourceLabel: Record<ReleaseLedgerSource, string> = { gitPush: "推送记录", remoteReview: "PR/MR 记录", rollback: "恢复记录" };
const statusLabel: Record<ReleaseLedgerEntry["status"], string> = {
  pushVerified: "推送已核实（不代表合并或部署）",
  reviewVerified: "PR/MR 已核实（不代表合并或部署）",
  unconfirmed: "未核实",
  remoteDifferent: "远端不同",
  targetChanged: "目标已变化",
  evidenceMismatch: "证据无法复核或不一致",
  rollbackCandidateObserved: "恢复候选已观察",
  rollbackOtherHeadObserved: "恢复后观察到其他头",
};
const statuses = new Set(Object.keys(statusLabel));
const operations = new Set(["push", "pushRetry", "githubReview", "gitlabReview"]);

const sha = (value: unknown): value is string => typeof value === "string" && (value.length === 40 || value.length === 64) && /^[0-9a-f]+$/.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const rollbackObservations = new Set(["unconfirmed", "candidateObserved", "otherHeadObserved"]);
const rollbackStatuses = new Set(["rollbackCandidateObserved", "rollbackOtherHeadObserved", "unconfirmed", "targetChanged", "evidenceMismatch"]);
const rollbackCapacity = new Set(["available", "limited", "full", "unavailable"]);
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

function validRollbackDetail(value: unknown, entry: ReleaseLedgerEntry): boolean {
  if (!value || typeof value !== "object") return false;
  const detail = value as NonNullable<ReleaseLedgerEntry["rollback"]>;
  if (!uuid(detail.sourceRecordId)
    || !safeInt(detail.sourceRevision) || detail.sourceRevision < 1 || !sha(detail.sourceSha) || !sha(detail.parentSha)
    || !sha(detail.sourceTreeSha) || !sha(detail.targetTreeSha) || !safeInt(detail.changedPaths) || detail.changedPaths < 1 || detail.changedPaths > 200
    || !safeInt(detail.targetFiles) || detail.targetFiles < 0 || detail.targetFiles > 200 || !rollbackObservations.has(detail.latestObservation)
    || (detail.observedRemoteSha !== null && !sha(detail.observedRemoteSha))
    || (detail.candidateObservedAtEpochMs !== null && (!safeInt(detail.candidateObservedAtEpochMs) || detail.candidateObservedAtEpochMs <= 0))) return false;
  if (![detail.sourceSha, detail.parentSha, detail.sourceTreeSha, detail.targetTreeSha, ...(detail.observedRemoteSha ? [detail.observedRemoteSha] : [])].every((item) => item.length === entry.expectedSha.length)
    || detail.sourceTreeSha === detail.targetTreeSha || detail.sourceSha === entry.expectedSha) return false;
  const checked = entry.checkedAtEpochMs;
  if (detail.candidateObservedAtEpochMs !== null && (checked === null || detail.candidateObservedAtEpochMs < entry.startedAtEpochMs || detail.candidateObservedAtEpochMs > checked)) return false;
  if (detail.latestObservation === "unconfirmed" && detail.observedRemoteSha !== null) return false;
  if (detail.latestObservation === "candidateObserved" && (checked === null || detail.observedRemoteSha !== entry.expectedSha || detail.candidateObservedAtEpochMs === null)) return false;
  if (detail.latestObservation === "otherHeadObserved" && (checked === null || detail.observedRemoteSha === null || detail.observedRemoteSha === entry.expectedSha)) return false;
  return true;
}

function validRollbackDiagnostics(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const d = value as NonNullable<ReleaseLedgerSnapshot["rollbackDiagnostics"]>;
  const count = (item: unknown, max = 200): item is number => item === null || (safeInt(item) && item >= 0 && item <= max);
  return ["available", "unavailable"].includes(d.status) && rollbackCapacity.has(d.capacity)
    && count(d.globalRecords) && count(d.localRecords) && count(d.localUnresolved)
    && count(d.payloadBytes, 4194304) && count(d.remainingPayloadBytes, 4194304)
    && d.maxRecords === 200 && d.maxPayloadBytes === 4194304 && d.maxRecordBytes === 65536 && d.reservedObservationBytes === 51200
    && typeof d.scopePartial === "boolean" && Array.isArray(d.blockedTargets) && d.blockedTargets.length <= 400
    && d.blockedTargets.every((item) => item && typeof item.remoteUrl === "string" && item.remoteUrl.length <= 4096 && typeof item.branch === "string" && item.branch.length > 0
      && safeInt(item.localUnresolved) && item.localUnresolved >= 0 && item.localUnresolved <= 200 && typeof item.pendingElsewhere === "boolean")
    && safeInt(d.checkedAtEpochMs) && d.checkedAtEpochMs > 0
    && (d.status === "unavailable" ? d.capacity === "unavailable" && d.globalRecords === null && d.localRecords === null && d.localUnresolved === null && d.payloadBytes === null && d.remainingPayloadBytes === null && d.scopePartial && d.blockedTargets.length === 0 : d.capacity !== "unavailable");
}

function validSnapshot(snapshot: ReleaseLedgerSnapshot, sessionId: string): boolean {
  if (!snapshot || typeof snapshot !== "object" || snapshot.sessionId !== sessionId || !Array.isArray(snapshot.entries) || snapshot.entries.length > 600 || !snapshot.summary || typeof snapshot.summary !== "object") return false;
  const seen = new Set<string>();
  const sourceCounts: Record<ReleaseLedgerSource, number> = { gitPush: 0, remoteReview: 0, rollback: 0 };
  const partialSeen = new Set<ReleaseLedgerSource>();
  let verifiedPushes = 0;
  let verifiedReviews = 0;
  let needsAttention = 0;
  for (const entry of snapshot.entries) {
    if (!entry || typeof entry !== "object") return false;
    const sourceIsPush = entry.source === "gitPush";
    const sourceIsReview = entry.source === "remoteReview";
    const sourceIsRollback = entry.source === "rollback";
    const validSha = sha(entry.expectedSha);
    const validTimes = Number.isSafeInteger(entry.startedAtEpochMs) && entry.startedAtEpochMs > 0
      && (entry.checkedAtEpochMs === null || (Number.isSafeInteger(entry.checkedAtEpochMs) && entry.checkedAtEpochMs >= entry.startedAtEpochMs));
    const validOperation = sourceIsPush ? (entry.operation === "push" || entry.operation === "pushRetry") : sourceIsReview ? (entry.operation === "githubReview" || entry.operation === "gitlabReview") : sourceIsRollback && entry.operation === "rollbackAppend";
    const statusValue = typeof entry.status === "string" ? entry.status : "";
    const validStatus = sourceIsPush ? statusValue !== "reviewVerified" && !statusValue.startsWith("rollback") : sourceIsReview ? statusValue !== "pushVerified" && statusValue !== "remoteDifferent" && !statusValue.startsWith("rollback") : rollbackStatuses.has(statusValue);
    const validVerifiedTime = (entry.status !== "pushVerified" && entry.status !== "reviewVerified") || entry.checkedAtEpochMs !== null;
    if ((!sourceIsPush && !sourceIsReview && !sourceIsRollback) || typeof entry.recordId !== "string" || entry.recordId.length === 0 || entry.recordId.length > 160
      || typeof entry.branch !== "string" || entry.branch.length === 0 || entry.branch.length > 1024
      || typeof entry.remoteUrl !== "string" || entry.remoteUrl.length === 0 || entry.remoteUrl.length > 4096
      || (entry.targetBranch !== null && (typeof entry.targetBranch !== "string" || entry.targetBranch.length === 0 || entry.targetBranch.length > 1024))
      || !Number.isSafeInteger(entry.revision) || entry.revision <= 0 || !validSha || (!operations.has(entry.operation) && entry.operation !== "rollbackAppend") || !statuses.has(entry.status) || !validOperation || !validStatus || !validVerifiedTime || !validTimes || seen.has(`${entry.source}:${entry.recordId}`)) return false;
    if (sourceIsReview && entry.targetBranch === null) return false;
    if (sourceIsPush && entry.targetBranch !== null) return false;
    if (sourceIsRollback && (entry.targetBranch !== null || !entry.rollback || !validRollbackDetail(entry.rollback, entry))) return false;
    if (sourceIsRollback && entry.rollback && ((entry.status === "rollbackCandidateObserved" && entry.rollback.latestObservation !== "candidateObserved")
      || (entry.status === "rollbackOtherHeadObserved" && entry.rollback.latestObservation !== "otherHeadObserved")
      || (entry.status === "unconfirmed" && entry.rollback.latestObservation !== "unconfirmed"))) return false;
    if (!sourceIsRollback && entry.rollback != null) return false;
    seen.add(`${entry.source}:${entry.recordId}`);
    sourceCounts[entry.source] += 1;
    if (sourceCounts[entry.source] > 200) return false;
    if (entry.status === "pushVerified") verifiedPushes += 1;
    else if (entry.status === "reviewVerified") verifiedReviews += 1;
    else if (entry.status !== "rollbackCandidateObserved") needsAttention += 1;
  }
  if (!Array.isArray(snapshot.partialSources) || !snapshot.partialSources.every((source) => source === "gitPush" || source === "remoteReview" || source === "rollback")) return false;
  for (const source of snapshot.partialSources) { if (partialSeen.has(source) || sourceCounts[source] > 0) return false; partialSeen.add(source); }
  const summary = snapshot.summary;
  const rollbackEntries = snapshot.entries.filter((entry) => entry.source === "rollback");
  const hasRollbackFields = summary.rollbackTransactions !== undefined || summary.historicalCandidateObservations !== undefined || summary.unresolvedRollbackTransactions !== undefined || snapshot.rollbackDiagnostics !== undefined;
  if (hasRollbackFields && !validRollbackDiagnostics(snapshot.rollbackDiagnostics)) return false;
  if (snapshot.partialSources.includes("rollback") && (rollbackEntries.length > 0 || snapshot.rollbackDiagnostics?.status !== "unavailable")) return false;
  if (snapshot.rollbackDiagnostics?.status === "unavailable" && !snapshot.partialSources.includes("rollback")) return false;
  if (snapshot.rollbackDiagnostics?.status === "available") {
    const diagnostics = snapshot.rollbackDiagnostics;
    const localUnresolved = rollbackEntries.filter((entry) => entry.rollback?.candidateObservedAtEpochMs === null).length;
    const expectedRemaining = Math.max(diagnostics.maxPayloadBytes - (diagnostics.payloadBytes ?? 0) - diagnostics.reservedObservationBytes, 0);
    const expectedCapacity = diagnostics.globalRecords === diagnostics.maxRecords || expectedRemaining === 0 ? "full" : expectedRemaining < diagnostics.maxRecordBytes ? "limited" : "available";
    if (diagnostics.globalRecords === null || diagnostics.localRecords === null || diagnostics.localUnresolved === null || diagnostics.payloadBytes === null || diagnostics.remainingPayloadBytes === null
      || diagnostics.localRecords !== rollbackEntries.length || diagnostics.localUnresolved !== localUnresolved || (diagnostics.globalRecords ?? 0) < (diagnostics.localRecords ?? 0) || (diagnostics.localUnresolved ?? 0) > (diagnostics.localRecords ?? 0)
      || diagnostics.remainingPayloadBytes !== expectedRemaining || diagnostics.capacity !== expectedCapacity || diagnostics.scopePartial !== snapshot.partialSources.includes("gitPush")) return false;
    const visibleTargets = new Set(snapshot.entries.filter((entry) => entry.source === "gitPush" || entry.source === "rollback").map((entry) => `${entry.remoteUrl}\u0000${entry.branch}`));
    const pendingByTarget = new Map<string, number>();
    for (const entry of rollbackEntries) if (entry.rollback?.candidateObservedAtEpochMs === null) pendingByTarget.set(`${entry.remoteUrl}\u0000${entry.branch}`, (pendingByTarget.get(`${entry.remoteUrl}\u0000${entry.branch}`) ?? 0) + 1);
    const blockedKeys = new Set<string>();
    for (const target of diagnostics.blockedTargets) {
      const key = `${target.remoteUrl}\u0000${target.branch}`;
      if (blockedKeys.has(key) || !visibleTargets.has(key) || (target.localUnresolved === 0 && !target.pendingElsewhere) || target.localUnresolved !== (pendingByTarget.get(key) ?? 0)) return false;
      blockedKeys.add(key);
    }
    for (const [key, count] of pendingByTarget) if (!blockedKeys.has(key) || count <= 0) return false;
  }
  if (!hasRollbackFields && rollbackEntries.length === 0) return Array.isArray(snapshot.warnings) && snapshot.warnings.length <= 50 && snapshot.warnings.every((warning) => typeof warning === "string" && warning.length <= 1000)
    && !!summary && [summary.total, summary.verifiedPushes, summary.verifiedReviews, summary.needsAttention].every((value) => safeInt(value) && value >= 0)
    && summary.total === snapshot.entries.length && summary.verifiedPushes === verifiedPushes
    && summary.verifiedReviews === verifiedReviews && summary.needsAttention === needsAttention;
  const rollbackTransactions = rollbackEntries.length;
  const historicalCandidateObservations = rollbackEntries.filter((entry) => entry.rollback?.candidateObservedAtEpochMs !== null).length;
  const unresolvedRollbackTransactions = rollbackEntries.filter((entry) => entry.rollback?.candidateObservedAtEpochMs === null).length;
  return Array.isArray(snapshot.warnings) && snapshot.warnings.length <= 50 && snapshot.warnings.every((warning) => typeof warning === "string" && warning.length <= 1000)
    && !!summary && [summary.total, summary.verifiedPushes, summary.verifiedReviews, summary.needsAttention, summary.rollbackTransactions, summary.historicalCandidateObservations, summary.unresolvedRollbackTransactions].every((value) => safeInt(value) && value >= 0)
    && summary.total === snapshot.entries.length && summary.verifiedPushes === verifiedPushes && summary.verifiedReviews === verifiedReviews && summary.needsAttention === needsAttention
    && summary.rollbackTransactions === rollbackTransactions && summary.historicalCandidateObservations === historicalCandidateObservations && summary.unresolvedRollbackTransactions === unresolvedRollbackTransactions;
}

export function ReleaseLedgerPanel({ archiveGateway, gateway, rollbackGateway, previewGateway, candidateGateway, transactionGateway, sessionId, enabled, disabled = false, refreshKey = 0, onOpenSource, deployment, focusRecordId: requestedFocusRecordId = null, focusRequest: requestedFocusRequest = 0 }: ReleaseLedgerPanelProps) {
  const { t, locale } = useI18n();
  const [rollbackRevision, setRollbackRevision] = useState(0);
  const [focusRecordId, setFocusRecordId] = useState<string | null>(requestedFocusRecordId);
  const [focusRequest, setFocusRequest] = useState(requestedFocusRequest);
  const [snapshot, setSnapshot] = useState<ReleaseLedgerSnapshot | null>(null);
  const [loadedContext, setLoadedContext] = useState<{ gateway: ReleaseLedgerGateway; sessionId: string; refreshKey: number; rollbackRevision: number } | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [page, setPage] = useState(0);
  const generation = useRef(0);
  const loadingRef = useRef(false);
  const contextRef = useRef<{ gateway: ReleaseLedgerGateway; sessionId: string; enabled: boolean; disabled: boolean }>({ gateway, sessionId, enabled, disabled });
  contextRef.current = { gateway, sessionId, enabled, disabled };

  useEffect(() => { setFocusRecordId(requestedFocusRecordId); setFocusRequest(requestedFocusRequest); }, [requestedFocusRecordId, requestedFocusRequest]);

  useEffect(() => {
    const requestGeneration = ++generation.current;
    loadingRef.current = false;
    setSnapshot(null);
    setLoadedContext(null);
    setError("");
    setPage(0);
    if (!enabled || disabled || !sessionId) { setLoading(false); return; }
    loadingRef.current = true;
    setLoading(true);
    void gateway.getReleaseLedger(sessionId).then((next) => {
      if (requestGeneration !== generation.current) return;
      if (!validSnapshot(next, sessionId)) throw new Error("invalid response");
      setSnapshot(next);
      setLoadedContext({ gateway, sessionId, refreshKey, rollbackRevision });
    }).catch(() => {
      if (requestGeneration !== generation.current) return;
      setSnapshot(null);
      setError(genericError);
    }).finally(() => {
      if (requestGeneration === generation.current) {
        loadingRef.current = false;
        setLoading(false);
      }
    });
    return () => { generation.current += 1; loadingRef.current = false; };
  }, [gateway, sessionId, enabled, disabled, refreshKey, rollbackRevision]);

  async function refresh() {
    if (loadingRef.current || !enabled || disabled || !sessionId) return;
    const requestGeneration = ++generation.current;
    loadingRef.current = true;
    setLoading(true);
    setError("");
    try {
      const next = await gateway.getReleaseLedger(sessionId);
      if (requestGeneration !== generation.current) return;
      if (!validSnapshot(next, sessionId)) throw new Error("invalid response");
      setSnapshot(next);
      setLoadedContext({ gateway, sessionId, refreshKey, rollbackRevision });
      setPage(0);
    } catch {
      if (requestGeneration === generation.current) { setSnapshot(null); setError(genericError); }
    } finally {
      if (requestGeneration === generation.current) { loadingRef.current = false; setLoading(false); }
    }
  }

  function refreshAfterRollbackObservation() {
    if (contextRef.current.gateway !== gateway || contextRef.current.sessionId !== sessionId || contextRef.current.enabled !== enabled || contextRef.current.disabled !== disabled) return;
    setRollbackRevision((value) => value + 1);
    setFocusRequest((value) => value + 1);
  }

  const currentSnapshot = snapshot && loadedContext?.gateway === gateway && loadedContext.sessionId === sessionId && loadedContext.refreshKey === refreshKey && loadedContext.rollbackRevision === rollbackRevision && enabled && !disabled ? snapshot : null;
  const partial = currentSnapshot?.partialSources ?? [];
  const entries = currentSnapshot?.entries ?? [];
  const pageCount = Math.max(1, Math.ceil(entries.length / pageSize));
  const visibleEntries = entries.slice(page * pageSize, (page + 1) * pageSize);
  const deploymentForSession = deployment?.sessionId === sessionId && deployment.snapshot.checkedAt !== null && deployment.snapshot.status !== "not_checked" ? deployment : null;

  return <section className="publish-section" aria-label={t("发布台账与手动恢复")} aria-busy={loading}>
    <div className="publish-actions"><h2>{t("发布台账与手动恢复")}</h2><button type="button" onClick={() => void refresh()} disabled={disabled || !enabled || loading}>{t("刷新台账")}</button></div>
    <p className="publish-muted">{t("刷新只读取本地台账。远端回滚计划、执行和恢复查询各需明确点击；台账本身不会自动联网、推送或删除记录。推送已核实、PR/MR 已核实均不代表合并或部署。")}</p>
    {error && <p className="publish-warning" role="alert">{t(error)}</p>}
    {!enabled || disabled ? <p className="publish-muted">{t("当前环境不可用。")}</p> : loading ? <p className="publish-muted">{t("正在读取本地发布台账…")}</p> : currentSnapshot && <div>
      {partial.length > 0 && <p className="publish-warning">{t("部分来源未能读取：{sources}。以下记录和摘要不代表完整台账，不能据此判断全部无记录或整体健康。", { sources: partial.map((source) => t(sourceLabel[source])).join(locale === "zh-CN" ? "、" : ", ") })}</p>}
      {currentSnapshot.warnings.map((warning, index) => <p className="publish-warning" key={`${index}:${warning}`}>{warning}</p>)}
      <div className="publish-muted" aria-label={t("台账摘要")}>{t("当前可见台账摘要：共 {total} 条，推送已核实 {pushes} 条，PR/MR 已核实 {reviews} 条，需关注 {attention} 条。", { total: currentSnapshot.summary.total, pushes: currentSnapshot.summary.verifiedPushes, reviews: currentSnapshot.summary.verifiedReviews, attention: currentSnapshot.summary.needsAttention })}</div>
      {currentSnapshot.rollbackDiagnostics ? <div className="publish-muted" aria-label={t("本地恢复诊断")}>
        {t("本地恢复诊断：{status}，容量{capacity}；本仓库未决 {unresolved} 条，全局记录 {global} 条。占用 {bytes} / {maxBytes} 字节；为新记录剩余 {remaining} 字节，已预留后续观察空间。容量状态不保证新记录可写入，执行仍需重新检查。", {
          status: t(currentSnapshot.rollbackDiagnostics.status === "available" ? "可用" : "不可用"),
          capacity: t(currentSnapshot.rollbackDiagnostics.capacity === "available" ? "有剩余空间" : currentSnapshot.rollbackDiagnostics.capacity === "limited" ? "空间有限" : currentSnapshot.rollbackDiagnostics.capacity === "full" ? "已达到容量上限" : "不可用"),
          unresolved: currentSnapshot.rollbackDiagnostics.localUnresolved ?? t("未知"), global: currentSnapshot.rollbackDiagnostics.globalRecords ?? t("未知"),
          bytes: currentSnapshot.rollbackDiagnostics.payloadBytes ?? t("未知"), maxBytes: currentSnapshot.rollbackDiagnostics.maxPayloadBytes, remaining: currentSnapshot.rollbackDiagnostics.remainingPayloadBytes ?? t("未知"),
        })}
        {currentSnapshot.rollbackDiagnostics.scopePartial && t("已知目标范围不完整，不能据此判断全部分支没有未决事务。")}
        {t("该状态只来自本地读取，不会自动联网。")}
        {currentSnapshot.rollbackDiagnostics.blockedTargets.length > 0 && <>{t("受阻目标：{targets}", { targets: currentSnapshot.rollbackDiagnostics.blockedTargets.map((target) => t("{remote} / {branch}（本地未决 {count}，{pending}）", { remote: target.remoteUrl, branch: target.branch, count: target.localUnresolved, pending: t(target.pendingElsewhere ? "其他位置仍有待处理" : "无其他位置待处理") })).join(locale === "zh-CN" ? "、" : ", ") })}</>}
      </div> : <div className="publish-muted" aria-label={t("本地恢复诊断")}>{t("本地恢复诊断：旧版台账未提供诊断，状态不可用。")}</div>}
      {currentSnapshot.summary.rollbackTransactions !== undefined && <div className="publish-muted" aria-label={t("恢复摘要")}>{t("恢复事务 {transactions} 条；历史首次观察到候选 {observations} 条；首次观察仍未明 {unresolved} 条。历史首次观察即使之后目标已变化仍保留。", { transactions: currentSnapshot.summary.rollbackTransactions, observations: currentSnapshot.summary.historicalCandidateObservations ?? 0, unresolved: currentSnapshot.summary.unresolvedRollbackTransactions ?? 0 })}</div>}
      {deploymentForSession && <p className="publish-muted">{t("已查询到部署观察：{summary}。该观察未关联冻结提交，不计入已部署或成功统计。", { summary: deploymentForSession.snapshot.summary })}</p>}
      {entries.length === 0 ? <p className="publish-muted">{t("当前可见来源没有记录；部分来源未读取时，不能据此判断全部无记录。")}</p> : <div>
        {visibleEntries.map((entry) => <article className="operation-plan" key={`${entry.source}:${entry.recordId}`}>
          <h3>{t(sourceLabel[entry.source])} · {t(statusLabel[entry.status])}</h3>
          {entry.status === "remoteDifferent" && <p className="publish-warning">{t("上次核实时远端引用不同；这只是历史观察，不会自动重推。")}</p>}
          {entry.source === "rollback" && <p className="publish-muted">{t("这是恢复事务的历史观察；最新观察与历史首次观察分开显示，不能证明谁执行、合并或部署。")}</p>}
          <dl>
            <dt>{t("记录 ID")}</dt><dd>{entry.recordId}</dd>
            <dt>{t("分支")}</dt><dd>{entry.branch}</dd>
            <dt>{t("目标 SHA")}</dt><dd>{entry.expectedSha}</dd>
            <dt>{t("开始时间")}</dt><dd>{new Date(entry.startedAtEpochMs).toLocaleString(locale)}</dd>
            <dt>{t("核实时间")}</dt><dd>{entry.checkedAtEpochMs === null ? t("尚未核实") : new Date(entry.checkedAtEpochMs).toLocaleString(locale)}</dd>
            {entry.source === "rollback" && entry.rollback && <>
              <dt>{t("冻结远端")}</dt><dd>{entry.remoteUrl}</dd>
              <dt>{t("冻结来源记录")}</dt><dd>{entry.rollback.sourceRecordId} / revision {entry.rollback.sourceRevision}</dd>
              <dt>{t("冻结来源 SHA")}</dt><dd>{entry.rollback.sourceSha}</dd>
              <dt>{t("父提交 / 源树 / 目标树")}</dt><dd>{entry.rollback.parentSha} / {entry.rollback.sourceTreeSha} / {entry.rollback.targetTreeSha}</dd>
              <dt>{t("变更路径 / 目标文件")}</dt><dd>{entry.rollback.changedPaths} / {entry.rollback.targetFiles}</dd>
              <dt>{t("最近一次观察")}</dt><dd>{entry.rollback.latestObservation === "candidateObserved" ? t("当前观察到候选") : entry.rollback.latestObservation === "otherHeadObserved" ? t("当前观察到其他头") : t("结果未明")}</dd>
              <dt>{t("观察到的远端 SHA")}</dt><dd>{entry.rollback.observedRemoteSha ?? t("未知")}</dd>
              <dt>{t("历史首次观察到候选")}</dt><dd>{entry.rollback.candidateObservedAtEpochMs === null ? t("尚无精确候选观察") : new Date(entry.rollback.candidateObservedAtEpochMs).toLocaleString(locale)}</dd>
            </>}
          </dl>
          {onOpenSource && entry.source !== "rollback" && <button type="button" onClick={() => onOpenSource(entry.source)}>{t("查看{source}", { source: t(sourceLabel[entry.source]) })}</button>}
          {entry.source === "rollback" && transactionGateway && <button type="button" onClick={() => { setFocusRecordId(entry.recordId); setFocusRequest((value) => value + 1); }}>{t("定位恢复历史")}</button>}
          {entry.source === "gitPush" && rollbackGateway && <RollbackQualificationPanel gateway={rollbackGateway} sessionId={sessionId} entry={entry} enabled={Boolean(currentSnapshot && enabled && !loading)} disabled={disabled} />}
          {entry.source === "gitPush" && previewGateway && <RollbackChangePreviewPanel gateway={previewGateway} sessionId={sessionId} entry={entry} enabled={Boolean(currentSnapshot && enabled && !loading)} disabled={disabled} />}
          {entry.source === "gitPush" && candidateGateway && <RollbackCandidatePanel gateway={candidateGateway} sessionId={sessionId} entry={entry} enabled={Boolean(currentSnapshot && enabled && !loading)} disabled={disabled} />}
          {entry.source === "gitPush" && transactionGateway && <RollbackTransactionPanel gateway={transactionGateway} sessionId={sessionId} entry={entry} enabled={Boolean(currentSnapshot && enabled && !loading)} disabled={disabled} onRecorded={refreshAfterRollbackObservation} />}
        </article>)}
        <div className="publish-actions" aria-label={t("台账分页")}><button type="button" onClick={() => setPage((current) => Math.max(0, current - 1))} disabled={page === 0}>{t("上一页")}</button><span className="publish-muted">{t("第 {page} / {pages} 页（每页最多 50 条）", { page: page + 1, pages: pageCount })}</span><button type="button" onClick={() => setPage((current) => Math.min(pageCount - 1, current + 1))} disabled={page >= pageCount - 1}>{t("下一页")}</button></div>
      </div>}
    </div>}
    {archiveGateway && <RollbackArchivePanel gateway={archiveGateway} sessionId={sessionId} enabled={enabled && !loading} disabled={disabled} refreshKey={refreshKey + rollbackRevision} />}
    {transactionGateway && <RollbackHistoryPanel gateway={transactionGateway} sessionId={sessionId} enabled={enabled} disabled={disabled} refreshKey={`${refreshKey}:${rollbackRevision}`} focusRecordId={focusRecordId} focusRequest={focusRequest} onObserved={refreshAfterRollbackObservation} />}
  </section>;
}
