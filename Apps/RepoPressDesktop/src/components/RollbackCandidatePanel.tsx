import { useEffect, useRef, useState } from "react";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type {
  RollbackCandidateBlocker,
  RollbackCandidateGateway,
  RollbackCandidatePlan,
  RollbackCandidateReport,
} from "../contracts/rollbackCandidate";
import { useI18n } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";

export interface RollbackCandidatePanelProps {
  gateway: RollbackCandidateGateway;
  sessionId: string;
  entry: ReleaseLedgerEntry;
  enabled: boolean;
  disabled?: boolean;
}

const blockerLabels: Record<RollbackCandidateBlocker, string> = {
  recordUnconfirmed: "推送记录未核实", objectsUnavailable: "本地对象不可用", rootCommit: "目标是根提交，缺少父提交",
  mergeCommit: "目标是合并提交", targetChanged: "目标分支或远端已变化", evidenceMismatch: "证据不一致",
  previewIncomplete: "变更预览不完整", targetSnapshotUnsupported: "目标快照包含不支持的类型",
  targetSnapshotUnsafe: "目标快照包含不安全路径", snapshotLimit: "目标快照达到读取上限", noChanges: "没有可生成的变更",
};
const blockerSet = new Set(Object.keys(blockerLabels));
const localParentlessBlockers = new Set<RollbackCandidateBlocker>(["recordUnconfirmed", "rootCommit", "mergeCommit", "targetChanged", "evidenceMismatch"]);
const snapshotParentBlockers = new Set<RollbackCandidateBlocker>(["previewIncomplete", "targetSnapshotUnsupported", "targetSnapshotUnsafe", "snapshotLimit", "noChanges"]);
const sha = (value: unknown): value is string => typeof value === "string" && (value.length === 40 || value.length === 64) && /^[0-9a-f]+$/.test(value);
const sameWidth = (a: string, b: string) => a.length === b.length;
const planId = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const unique = (items: unknown[]) => new Set(items).size === items.length;
const identityKey = (sessionId: string, entry: ReleaseLedgerEntry) => [sessionId, entry.source, entry.recordId, entry.revision, entry.operation, entry.status, entry.checkedAtEpochMs ?? "null", entry.branch, entry.targetBranch ?? "", entry.remoteUrl, entry.expectedSha].join("\u0000");
const identityMatches = (value: RollbackCandidatePlan | RollbackCandidateReport, sessionId: string, entry: ReleaseLedgerEntry) =>
  value.sessionId === sessionId && value.recordId === entry.recordId && value.revision === entry.revision && value.branch === entry.branch
  && value.remoteUrl === entry.remoteUrl && value.expectedSha === entry.expectedSha;
const blockersValid = (value: unknown): value is RollbackCandidateBlocker[] => Array.isArray(value) && unique(value) && value.every((item) => typeof item === "string" && blockerSet.has(item));
const checkedAtValid = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value > 0;

function validPlan(value: unknown, sessionId: string, entry: ReleaseLedgerEntry): value is RollbackCandidatePlan {
  if (!value || typeof value !== "object") return false;
  const plan = value as RollbackCandidatePlan;
  if (!identityMatches(plan, sessionId, entry) || !sha(plan.expectedSha) || !blockersValid(plan.blockers) || !checkedAtValid(plan.checkedAtEpochMs)) return false;
  if (plan.status === "ready") {
    return entry.source === "gitPush" && entry.status === "pushVerified" && entry.checkedAtEpochMs !== null && sha(plan.parentSha)
      && sha(plan.sourceTreeSha) && sha(plan.targetTreeSha) && sameWidth(plan.parentSha, plan.expectedSha) && sameWidth(plan.sourceTreeSha, plan.expectedSha) && sameWidth(plan.targetTreeSha, plan.expectedSha) && plan.sourceTreeSha !== plan.targetTreeSha
      && planId(plan.planId) && plan.blockers.length === 0 && Number.isSafeInteger(plan.changedPaths) && plan.changedPaths >= 1 && plan.changedPaths <= 200
      && Number.isSafeInteger(plan.targetFiles) && plan.targetFiles >= 0 && plan.targetFiles <= 200
      && typeof plan.expiresAtEpochMs === "number" && Number.isSafeInteger(plan.expiresAtEpochMs) && plan.expiresAtEpochMs > Date.now()
      && plan.expiresAtEpochMs > plan.checkedAtEpochMs && plan.expiresAtEpochMs - plan.checkedAtEpochMs <= 5 * 60 * 1000;
  }
  if (plan.status !== "blocked" || plan.sourceTreeSha !== null || plan.targetTreeSha !== null || plan.changedPaths !== 0 || plan.targetFiles !== 0
    || plan.blockers.length === 0 || plan.planId !== null || plan.expiresAtEpochMs !== null) return false;
  if (plan.blockers.some((blocker) => localParentlessBlockers.has(blocker))) return plan.parentSha === null;
  if (plan.blockers.some((blocker) => snapshotParentBlockers.has(blocker))) return sha(plan.parentSha) && sameWidth(plan.parentSha, plan.expectedSha);
  return plan.parentSha === null || (sha(plan.parentSha) && sameWidth(plan.parentSha, plan.expectedSha));
}

function validReport(value: unknown, accepted: RollbackCandidatePlan): value is RollbackCandidateReport {
  if (!value || typeof value !== "object" || accepted.status !== "ready") return false;
  const report = value as RollbackCandidateReport;
  return identityMatches(report, accepted.sessionId, { ...({} as ReleaseLedgerEntry), recordId: accepted.recordId, revision: accepted.revision, branch: accepted.branch, remoteUrl: accepted.remoteUrl, expectedSha: accepted.expectedSha } as ReleaseLedgerEntry)
    && report.parentSha === accepted.parentSha && report.planId === accepted.planId && report.sourceTreeSha === accepted.sourceTreeSha
    && report.targetTreeSha === accepted.targetTreeSha && report.changedPaths === accepted.changedPaths && report.targetFiles === accepted.targetFiles
    && sha(report.candidateSha) && sameWidth(report.candidateSha, accepted.expectedSha) && report.candidateSha !== accepted.expectedSha
    && checkedAtValid(report.generatedAtEpochMs) && report.generatedAtEpochMs >= accepted.checkedAtEpochMs && report.generatedAtEpochMs < (accepted.expiresAtEpochMs ?? 0)
    && report.temporaryObjectsRemoved === true;
}

export function RollbackCandidatePanel({ gateway, sessionId, entry, enabled, disabled = false }: RollbackCandidatePanelProps) {
  const { locale, t } = useI18n();
  const [plan, setPlan] = useState<RollbackCandidatePlan | null>(null);
  const [report, setReport] = useState<RollbackCandidateReport | null>(null);
  const [busy, setBusy] = useState<"planning" | "generating" | null>(null);
  const [error, setError] = useState<UiMessage | null>(null);
  const [loadedContext, setLoadedContext] = useState<{ gateway: RollbackCandidateGateway; key: string } | null>(null);
  const generation = useRef(0); const busyRef = useRef(false); const readyRef = useRef<RollbackCandidatePlan | null>(null);
  const key = identityKey(sessionId, entry); const usable = enabled && !disabled && Boolean(sessionId) && entry.source === "gitPush";

  const discard = (candidate: RollbackCandidatePlan | null, boundSession = sessionId) => {
    if (candidate?.status === "ready" && candidate.planId) void gateway.discardRollbackCandidate(boundSession, candidate.planId).catch(() => undefined);
  };
  useEffect(() => {
    const old = readyRef.current; readyRef.current = null; discard(old);
    generation.current += 1; busyRef.current = false; setPlan(null); setReport(null); setLoadedContext(null); setBusy(null); setError(null);
    return () => { const current = readyRef.current; readyRef.current = null; discard(current); generation.current += 1; busyRef.current = false; };
  }, [gateway, key, enabled, disabled]);

  const contextCurrent = loadedContext?.gateway === gateway && loadedContext.key === key && usable;
  const planCurrent = contextCurrent && plan && plan.sessionId === sessionId && plan.recordId === entry.recordId && plan.revision === entry.revision && plan.branch === entry.branch && plan.remoteUrl === entry.remoteUrl && plan.expectedSha === entry.expectedSha ? plan : null;
  const reportCurrent = contextCurrent && report && report.sessionId === sessionId && report.recordId === entry.recordId && report.revision === entry.revision && report.branch === entry.branch && report.remoteUrl === entry.remoteUrl && report.expectedSha === entry.expectedSha ? report : null;
  const expired = !planCurrent || planCurrent.status !== "ready" || planCurrent.expiresAtEpochMs === null || planCurrent.expiresAtEpochMs <= Date.now();
  const canGenerate = Boolean(planCurrent?.status === "ready" && planCurrent.planId && !expired && planCurrent.blockers.length === 0);

  async function prepare() {
    if (!usable || busyRef.current) return;
    const previous = readyRef.current; readyRef.current = null; discard(previous);
    busyRef.current = true; const request = ++generation.current; const requestSession = sessionId; setBusy("planning"); setError(null); setPlan(null); setReport(null);
    try {
      const next = await gateway.planRollbackCandidate(requestSession, entry.recordId, entry.revision);
      if (request !== generation.current) { const stale = next as Partial<RollbackCandidatePlan>; if (stale.status === "ready" && planId(stale.planId)) discard(stale as RollbackCandidatePlan, requestSession); return; }
      if (!validPlan(next, requestSession, entry)) {
        const invalid = next as Partial<RollbackCandidatePlan>;
        if (invalid.status === "ready" && planId(invalid.planId) && identityMatches(invalid as RollbackCandidatePlan, requestSession, entry)) discard(invalid as RollbackCandidatePlan, requestSession);
        throw new Error("invalid response");
      }
      setLoadedContext({ gateway, key }); setPlan(next); readyRef.current = next.status === "ready" ? next : null;
    } catch { if (request === generation.current) setError({ source: "无法读取本地回滚候选条件，请稍后重试。" }); }
    finally { if (request === generation.current) { busyRef.current = false; setBusy(null); } }
  }
  async function generate() {
    const captured = planCurrent;
    if (!usable || busyRef.current || !captured || !canGenerate || !captured.planId) return;
    if (captured.expiresAtEpochMs === null || captured.expiresAtEpochMs <= Date.now()) { readyRef.current = null; discard(captured); setPlan(null); setError({ source: "候选计划已过期，请重新准备。" }); return; }
    busyRef.current = true; const request = ++generation.current; const requestSession = sessionId; readyRef.current = null; setBusy("generating"); setError(null); setPlan(null); setReport(null);
    try {
      const next = await gateway.generateRollbackCandidate(requestSession, captured.planId);
      if (request !== generation.current) return;
      if (!validReport(next, captured)) throw new Error("invalid response");
      setLoadedContext({ gateway, key }); setReport(next);
    } catch { if (request === generation.current) setError({ source: "无法生成本地回滚候选；计划已消费，请重新准备。" }); }
    finally { if (request === generation.current) { busyRef.current = false; setBusy(null); } }
  }
  useEffect(() => {
    if (!planCurrent || planCurrent.status !== "ready" || planCurrent.expiresAtEpochMs === null) return;
    const timer = window.setTimeout(() => { const old = readyRef.current; readyRef.current = null; discard(old); setPlan(null); setError({ source: "候选计划已过期，请重新准备。" }); }, Math.max(0, planCurrent.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [planCurrent?.planId, planCurrent?.expiresAtEpochMs]);

  const labels = (items: RollbackCandidateBlocker[]) => items.length ? items.map((item) => t(blockerLabels[item] ?? "未知阻塞条件")).join(t("、")) : t("无");
  return <section className="operation-plan" aria-label={t("本地逆向提交候选")} aria-busy={busy !== null}>
    <h4>{t("本地逆向提交候选")}</h4>
    <p className="publish-muted">{t("只在本地生成临时候选对象；不会访问网络、远端或执行回滚。候选报告不提供任何执行授权。")}</p>
    <button type="button" onClick={() => void prepare()} disabled={!usable || busy !== null}>{t("准备候选计划")}</button>
    {busy === "planning" && <p role="status" className="publish-muted">{t("正在读取本地提交和树对象…")}</p>}
    {busy === "generating" && <p role="status" className="publish-muted">{t("正在生成临时本地候选…")}</p>}
    {error && <p role="alert" className="publish-warning">{renderUiMessage(error, t)}</p>}
    {planCurrent?.status === "blocked" && <div className="publish-warning"><p>{t("候选计划被阻塞：{blockers}", { blockers: labels(planCurrent.blockers) })}</p><p>{t("没有可确认的本地候选。")}</p></div>}
    {planCurrent?.status === "ready" && <div className="operation-plan"><p><strong>{t("候选计划已准备")}</strong></p><dl><dt>{t("冻结提交 SHA")}</dt><dd>{planCurrent.expectedSha}</dd><dt>{t("父提交 SHA")}</dt><dd>{planCurrent.parentSha}</dd><dt>{t("源树 SHA")}</dt><dd>{planCurrent.sourceTreeSha}</dd><dt>{t("目标树 SHA")}</dt><dd>{planCurrent.targetTreeSha}</dd><dt>{t("变更路径")}</dt><dd>{planCurrent.changedPaths}</dd><dt>{t("目标文件")}</dt><dd>{planCurrent.targetFiles}</dd><dt>{t("检查时间")}</dt><dd>{new Date(planCurrent.checkedAtEpochMs).toLocaleString(locale)}</dd><dt>{t("有效期至")}</dt><dd>{new Date(planCurrent.expiresAtEpochMs ?? 0).toLocaleString(locale)}</dd></dl><p className="publish-muted">{t("确认后计划立即消费；生成完成后临时对象会被清理。")}</p><button type="button" onClick={() => void generate()} disabled={!canGenerate || busy !== null}>{t("确认生成本地候选")}</button><button type="button" onClick={() => { const old = readyRef.current; readyRef.current = null; discard(old); setPlan(null); setReport(null); setError(null); }} disabled={busy !== null}>{t("取消候选计划")}</button></div>}
    {reportCurrent && <div className="operation-plan"><p><strong>{t("临时本地候选已生成")}</strong></p><dl><dt>{t("候选 SHA")}</dt><dd>{reportCurrent.candidateSha}</dd><dt>{t("冻结提交 SHA")}</dt><dd>{reportCurrent.expectedSha}</dd><dt>{t("候选父提交（冻结提交）")}</dt><dd>{reportCurrent.expectedSha}</dd><dt>{t("恢复来源父提交")}</dt><dd>{reportCurrent.parentSha}</dd><dt>{t("源树 SHA")}</dt><dd>{reportCurrent.sourceTreeSha}</dd><dt>{t("目标树 SHA")}</dt><dd>{reportCurrent.targetTreeSha}</dd><dt>{t("变更路径")}</dt><dd>{reportCurrent.changedPaths}</dd><dt>{t("目标文件")}</dt><dd>{reportCurrent.targetFiles}</dd><dt>{t("生成时间")}</dt><dd>{new Date(reportCurrent.generatedAtEpochMs).toLocaleString(locale)}</dd></dl><p>{t("临时对象已清理，候选 SHA 仅供审阅，不是持久对象或执行授权。")}</p></div>}
  </section>;
}
