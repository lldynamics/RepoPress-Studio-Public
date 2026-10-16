import { useEffect, useRef, useState } from "react";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type {
  RollbackBlocker,
  RollbackQualificationGateway,
  RollbackQualificationIdentity,
  RollbackQualificationPlan,
  RollbackQualificationReport,
} from "../contracts/rollbackQualification";
import { useI18n } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";

export interface RollbackQualificationPanelProps {
  gateway: RollbackQualificationGateway;
  sessionId: string;
  entry: ReleaseLedgerEntry;
  enabled: boolean;
  disabled?: boolean;
}

const blockerLabels: Record<RollbackBlocker, string> = {
  recordUnconfirmed: "推送记录未核实",
  objectsUnavailable: "本地对象不可用",
  rootCommit: "目标是根提交，缺少父提交",
  mergeCommit: "目标是合并提交",
  targetChanged: "目标分支或远端已变化",
  evidenceMismatch: "证据不一致",
  remoteDifferent: "远端头与目标不同",
  remoteUnavailable: "远端头不可查询",
};
const blockerSet = new Set(Object.keys(blockerLabels));
const sha = (value: unknown): value is string => typeof value === "string" && (value.length === 40 || value.length === 64) && /^[0-9a-f]+$/.test(value);
const text = (value: unknown, max = 4096): value is string => typeof value === "string" && value.length > 0 && value.length <= max;
const validIdentity = (value: RollbackQualificationIdentity, sessionId: string, entry: ReleaseLedgerEntry, parentSha: string | null): boolean =>
  value.sessionId === sessionId && value.recordId === entry.recordId && value.revision === entry.revision && value.branch === entry.branch
  && value.remoteUrl === entry.remoteUrl && value.expectedSha === entry.expectedSha && value.parentSha === parentSha;
const validBlockers = (value: unknown): value is RollbackBlocker[] => Array.isArray(value) && new Set(value).size === value.length && value.every((item) => typeof item === "string" && blockerSet.has(item));
const identityKey = (sessionId: string, entry: ReleaseLedgerEntry) => `${sessionId}\u0000${entry.source}\u0000${entry.recordId}\u0000${entry.revision}\u0000${entry.operation}\u0000${entry.status}\u0000${entry.checkedAtEpochMs ?? "null"}\u0000${entry.branch}\u0000${entry.remoteUrl}\u0000${entry.expectedSha}`;

function planValid(plan: RollbackQualificationPlan, sessionId: string, entry: ReleaseLedgerEntry): boolean {
  if (!validIdentity(plan, sessionId, entry, plan.parentSha) || !text(plan.branch) || !text(plan.remoteUrl) || !sha(plan.expectedSha)
    || !validBlockers(plan.blockers)) return false;
  if (plan.localStatus === "candidate") {
    return entry.status === "pushVerified" && entry.checkedAtEpochMs !== null && sha(plan.parentSha) && plan.blockers.length === 0 && text(plan.planId, 512)
      && typeof plan.expiresAtEpochMs === "number" && Number.isSafeInteger(plan.expiresAtEpochMs)
      && plan.expiresAtEpochMs > Date.now() && plan.expiresAtEpochMs <= Date.now() + 5 * 60 * 1000;
  }
  return plan.localStatus === "blocked" && plan.parentSha === null && plan.blockers.length > 0
    && !plan.blockers.includes("remoteDifferent") && !plan.blockers.includes("remoteUnavailable")
    && plan.planId === null && plan.expiresAtEpochMs === null;
}
function reportValid(report: RollbackQualificationReport, sessionId: string, entry: ReleaseLedgerEntry): boolean {
  if (!validIdentity(report, sessionId, entry, report.parentSha) || !text(report.branch) || !text(report.remoteUrl) || !sha(report.expectedSha)
    || !sha(report.parentSha) || !validBlockers(report.blockers) || !Number.isSafeInteger(report.checkedAtEpochMs) || report.checkedAtEpochMs <= 0
    || (report.remoteSha !== null && !sha(report.remoteSha))) return false;
  if (report.status === "qualified") return report.blockers.length === 0 && sha(report.parentSha) && report.remoteSha === report.expectedSha;
  if (report.blockers.length === 0) return false;
  if (report.status === "unknown") return report.blockers.length === 1 && report.blockers[0] === "remoteUnavailable" && report.remoteSha === null;
  if (report.status !== "blocked" || report.blockers.includes("remoteUnavailable")) return false;
  if (report.blockers.includes("remoteDifferent")) return report.remoteSha !== null && report.remoteSha !== report.expectedSha;
  return report.remoteSha === null;
}

export function RollbackQualificationPanel({ gateway, sessionId, entry, enabled, disabled = false }: RollbackQualificationPanelProps) {
  const { locale, t } = useI18n();
  const [plan, setPlan] = useState<RollbackQualificationPlan | null>(null);
  const [report, setReport] = useState<RollbackQualificationReport | null>(null);
  const [busy, setBusy] = useState<"planning" | "checking" | null>(null);
  const [error, setError] = useState<UiMessage | null>(null);
  const [loadedContext, setLoadedContext] = useState<{ gateway: RollbackQualificationGateway; key: string } | null>(null);
  const generation = useRef(0);
  const busyRef = useRef(false);
  const key = identityKey(sessionId, entry);
  const usable = enabled && !disabled && entry.source === "gitPush" && Boolean(sessionId);

  useEffect(() => {
    generation.current += 1;
    busyRef.current = false;
    setPlan(null); setReport(null); setLoadedContext(null); setBusy(null); setError(null);
    return () => { generation.current += 1; busyRef.current = false; };
  }, [gateway, key, enabled, disabled]);

  const contextCurrent = loadedContext?.gateway === gateway && loadedContext.key === key && usable;
  const planCurrent = contextCurrent && plan && plan.sessionId === sessionId && plan.recordId === entry.recordId && plan.revision === entry.revision && plan.branch === entry.branch && plan.remoteUrl === entry.remoteUrl && plan.expectedSha === entry.expectedSha ? plan : null;
  const reportCurrent = contextCurrent && report && report.sessionId === sessionId && report.recordId === entry.recordId && report.revision === entry.revision && report.branch === entry.branch && report.remoteUrl === entry.remoteUrl && report.expectedSha === entry.expectedSha ? report : null;
  const expired = !planCurrent || planCurrent.expiresAtEpochMs === null || planCurrent.expiresAtEpochMs <= Date.now() || planCurrent.expiresAtEpochMs > Date.now() + 5 * 60 * 1000;
  const canCheck = Boolean(planCurrent && planCurrent.localStatus === "candidate" && planCurrent.planId && planCurrent.parentSha && sha(planCurrent.parentSha) && !expired && planCurrent.blockers.length === 0);

  async function createPlan() {
    if (!usable || busyRef.current) return;
    busyRef.current = true; const request = ++generation.current; setBusy("planning"); setError(null); setPlan(null); setReport(null);
    try { const next = await gateway.planRollbackQualification(sessionId, entry.recordId, entry.revision); if (request !== generation.current) return; if (!planValid(next, sessionId, entry)) throw new Error("invalid response"); setLoadedContext({ gateway, key }); setPlan(next); }
    catch { if (request === generation.current) setError({ source: "无法读取回滚条件，请稍后重试。" }); }
    finally { if (request === generation.current) { busyRef.current = false; setBusy(null); } }
  }
  async function checkPlan() {
    const captured = planCurrent; if (!usable || busyRef.current || !captured || !canCheck || !captured.planId) return;
    if (captured.expiresAtEpochMs === null || captured.expiresAtEpochMs <= Date.now()) { setPlan(null); setError({ source: "只读查询计划已过期，请重新审阅回滚条件。" }); return; }
    busyRef.current = true; const request = ++generation.current; setBusy("checking"); setError(null); setReport(null); setPlan(null);
    try { const next = await gateway.checkRollbackQualification(sessionId, captured.planId); if (request !== generation.current) return; if (!reportValid(next, sessionId, entry) || next.parentSha !== captured.parentSha) throw new Error("invalid response"); setLoadedContext({ gateway, key }); setReport(next); }
    catch { if (request === generation.current) setError({ source: "只读远端头查询失败；该计划已消费，请重新审阅回滚条件。" }); }
    finally { if (request === generation.current) { busyRef.current = false; setBusy(null); } }
  }

  useEffect(() => {
    if (!planCurrent || planCurrent.localStatus !== "candidate" || planCurrent.expiresAtEpochMs === null) return;
    const delay = Math.max(0, planCurrent.expiresAtEpochMs - Date.now());
    const timer = window.setTimeout(() => { setPlan(null); setError({ source: "只读查询计划已过期，请重新审阅回滚条件。" }); }, delay);
    return () => window.clearTimeout(timer);
  }, [planCurrent?.planId, planCurrent?.expiresAtEpochMs]);

  const labels = (items: RollbackBlocker[]) => items.length ? items.map((item) => t(blockerLabels[item] ?? "未知阻塞条件")).join(t("、")) : t("无");
  return <section className="operation-plan" aria-label={t("只读回滚条件审阅")} aria-busy={busy !== null}>
    <h4>{t("回滚条件（只读资格审阅）")}</h4>
    <p className="publish-muted">{t("仅检查提交、父提交、根树是否存在，以及远端头是否精确匹配；不保证完整对象恢复或无冲突，也不授权执行回滚，不代表已合并或已部署。")}</p>
    <button type="button" onClick={() => void createPlan()} disabled={!usable || busy !== null}>{t("审阅回滚条件")}</button>
    {busy === "planning" && <p className="publish-muted" role="status">{t("正在读取本地回滚条件…")}</p>}
    {error && <p className="publish-warning" role="alert">{renderUiMessage(error, t)}</p>}
    {planCurrent?.localStatus === "blocked" && <div className="publish-warning"><p>{t("本地回滚条件被阻塞：{blockers}", { blockers: labels(planCurrent.blockers) })}</p><p>{t("无可确认的只读查询计划。")}</p></div>}
    {planCurrent?.localStatus === "candidate" && <div className="operation-plan"><p><strong>{t("只读查询候选")}</strong></p><dl><dt>{t("目标分支")}</dt><dd>{planCurrent.branch}</dd><dt>{t("远端 URL")}</dt><dd>{planCurrent.remoteUrl}</dd><dt>{t("冻结 SHA")}</dt><dd>{planCurrent.expectedSha}</dd><dt>{t("父 SHA")}</dt><dd>{planCurrent.parentSha ?? t("无")}</dd><dt>{t("有效期至")}</dt><dd>{planCurrent.expiresAtEpochMs ? new Date(planCurrent.expiresAtEpochMs).toLocaleString(locale) : t("无效")}</dd></dl><p className="publish-muted">{t("候选计划只允许一次远端头查询，不会执行任何回滚。")}</p><button type="button" onClick={() => void checkPlan()} disabled={!canCheck || busy !== null}>{t("确认只读查询远端头")}</button><button type="button" onClick={() => { setPlan(null); setReport(null); setError(null); }} disabled={busy !== null}>{t("取消只读查询")}</button></div>}
    {busy === "checking" && <p className="publish-muted" role="status">{t("正在查询远端头…")}</p>}
    {reportCurrent && <div className={reportCurrent.status === "qualified" ? "operation-plan" : "publish-warning"}><p><strong>{t(reportCurrent.status === "qualified" ? "查询时基础条件满足" : reportCurrent.status === "unknown" ? "查询结果未知" : "查询时条件被阻塞")}</strong></p><dl><dt>{t("查询时间")}</dt><dd>{new Date(reportCurrent.checkedAtEpochMs).toLocaleString(locale)}</dd><dt>{t("远端头 SHA")}</dt><dd>{reportCurrent.remoteSha ?? t("未知（未获得远端头）")}</dd><dt>{t("父 SHA")}</dt><dd>{reportCurrent.parentSha ?? t("无")}</dd></dl><p>{t("阻塞条件：{blockers}", { blockers: labels(reportCurrent.blockers) })}</p>{reportCurrent.status === "qualified" && <p>{t("远端头精确匹配冻结 SHA；父提交存在。此报告仅表示查询时基础条件满足，不保证完整 blob 恢复、无冲突或任何执行授权。")}</p>}{reportCurrent.status !== "qualified" && <p>{t("没有足够证据确认回滚条件。")}</p>}</div>}
  </section>;
}
