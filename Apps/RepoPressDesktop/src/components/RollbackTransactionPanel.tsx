import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import type { UiLocale } from "../i18n/locale";
import type { UiTranslator } from "../i18n/i18n";
import { useI18n } from "../i18n/i18n";
import { useEffect, useRef, useState } from "react";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type {
  RollbackRecord,
  RollbackTransactionGateway,
  RollbackTransactionPlan,
} from "../contracts/rollbackTransaction";

export interface RollbackTransactionPanelProps {
  gateway: RollbackTransactionGateway;
  sessionId: string;
  entry: ReleaseLedgerEntry;
  enabled: boolean;
  disabled?: boolean;
  onRecorded?: () => void;
}

export interface RollbackHistoryPanelProps {
  gateway: RollbackTransactionGateway;
  sessionId: string;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: string | number;
  focusRecordId?: string | null;
  focusRequest?: number;
  /** Called only after a valid explicit remote observation in the current context. */
  onObserved?: () => void;
}

const sha = (value: unknown): value is string => typeof value === "string" && (value.length === 40 || value.length === 64) && /^[0-9a-f]+$/.test(value);
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const sameWidth = (a: string, b: string) => a.length === b.length;
const when = (value: number | null | undefined, locale: UiLocale, t: UiTranslator) => typeof value === "number" ? new Date(value).toLocaleString(locale) : t("未提供");

function entryKey(sessionId: string, entry: ReleaseLedgerEntry) {
  return [sessionId, entry.source, entry.recordId, entry.revision, entry.operation, entry.branch, entry.targetBranch ?? "", entry.remoteUrl,
    entry.expectedSha, entry.startedAtEpochMs, entry.checkedAtEpochMs ?? "null", entry.status].join("\u0000");
}

function matchesEntry(value: RollbackTransactionPlan, sessionId: string, entry: ReleaseLedgerEntry) {
  return value.sessionId === sessionId && value.recordId === entry.recordId && value.revision === entry.revision && value.branch === entry.branch
    && value.remoteUrl === entry.remoteUrl && value.expectedSha === entry.expectedSha;
}

function validPlan(value: unknown, sessionId: string, entry: ReleaseLedgerEntry): value is RollbackTransactionPlan {
  if (!value || typeof value !== "object") return false;
  const plan = value as RollbackTransactionPlan;
  if (!matchesEntry(plan, sessionId, entry) || !sha(plan.expectedSha) || !safeInt(plan.checkedAtEpochMs) || plan.checkedAtEpochMs <= 0
    || !Array.isArray(plan.blockers) || new Set(plan.blockers).size !== plan.blockers.length) return false;
  if (!plan.blockers.every((item) => typeof item === "string" && item in blockerLabel)) return false;
  if (plan.status === "ready") {
    return entry.source === "gitPush" && entry.status === "pushVerified" && entry.checkedAtEpochMs !== null
      && plan.checkedAtEpochMs >= entry.checkedAtEpochMs && uuid(plan.planId) && plan.blockers.length === 0
      && sha(plan.parentSha) && sha(plan.sourceTreeSha) && sha(plan.targetTreeSha) && sha(plan.candidateSha)
      && sha(plan.observedRemoteSha) && plan.observedRemoteSha === plan.expectedSha
      && sameWidth(plan.parentSha, plan.expectedSha) && sameWidth(plan.sourceTreeSha, plan.expectedSha) && sameWidth(plan.targetTreeSha, plan.expectedSha)
      && sameWidth(plan.candidateSha, plan.expectedSha) && plan.candidateSha !== plan.expectedSha
      && plan.sourceTreeSha !== plan.targetTreeSha && safeInt(plan.changedPaths) && plan.changedPaths >= 1 && plan.changedPaths <= 200
      && safeInt(plan.targetFiles) && plan.targetFiles >= 0 && plan.targetFiles <= 200
      && safeInt(plan.expiresAtEpochMs) && plan.expiresAtEpochMs > Date.now() && plan.expiresAtEpochMs > plan.checkedAtEpochMs
      && plan.expiresAtEpochMs - plan.checkedAtEpochMs <= 5 * 60 * 1000;
  }
  return plan.status === "blocked" && plan.planId === null && plan.expiresAtEpochMs === null && plan.candidateSha === null
    && (plan.observedRemoteSha === null || (sha(plan.observedRemoteSha) && sameWidth(plan.observedRemoteSha, plan.expectedSha))) && plan.sourceTreeSha === null && plan.targetTreeSha === null && plan.changedPaths === 0 && plan.targetFiles === 0
    && plan.blockers.length > 0 && (plan.parentSha === null || (sha(plan.parentSha) && sameWidth(plan.parentSha, plan.expectedSha)))
    && (plan.blockers.includes("remoteDifferent") ? (sha(plan.observedRemoteSha) && sameWidth(plan.observedRemoteSha, plan.expectedSha) && plan.observedRemoteSha !== plan.expectedSha) : plan.observedRemoteSha === null);
}

function validRecord(value: unknown, expected?: ReleaseLedgerEntry): value is RollbackRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as RollbackRecord;
  const source = record.source;
  if (!source || !source.evidence || !uuid(record.recordId) || !uuid(record.planId)
    || typeof record.sessionId !== "string" || record.sessionId.length < 1 || record.sessionId.length > 160
    || /[\u0000-\u001f\u007f]/.test(record.sessionId) || !safeInt(record.revision) || record.revision < 1) return false;
  if (!uuid(source.recordId) || !safeInt(source.revision) || source.revision < 1 || source.outcome !== "verified"
    || !safeInt(source.checkedAtEpochMs) || source.checkedAtEpochMs <= 0 || !safeInt(source.startedAtEpochMs) || source.startedAtEpochMs <= 0
    || !sha(source.evidence.expectedSha) || source.observedRemoteSha !== source.evidence.expectedSha
    || !["push", "pushRetry"].includes(source.evidence.operation)
    || typeof source.evidence.remoteUrl !== "string" || !source.evidence.remoteUrl || source.evidence.remoteUrl.length > 4096
    || typeof source.evidence.branch !== "string" || !source.evidence.branch || source.evidence.branch.length > 1024) return false;
  if (expected && (source.recordId !== expected.recordId || source.revision !== expected.revision || source.evidence.remoteUrl !== expected.remoteUrl
    || source.evidence.branch !== expected.branch || source.evidence.expectedSha !== expected.expectedSha
    || source.evidence.operation !== expected.operation || source.startedAtEpochMs !== expected.startedAtEpochMs
    || source.checkedAtEpochMs !== expected.checkedAtEpochMs)) return false;
  if (!sha(record.parentSha) || !sha(record.sourceTreeSha) || !sha(record.targetTreeSha) || !sha(record.candidateSha)
    || record.sourceTreeSha === record.targetTreeSha || record.candidateSha === source.evidence.expectedSha) return false;
  if (![record.parentSha, record.sourceTreeSha, record.targetTreeSha, source.evidence.expectedSha].every((item) => sameWidth(item, record.candidateSha))) return false;
  if (!safeInt(record.changedPaths) || record.changedPaths < 1 || record.changedPaths > 200 || !safeInt(record.targetFiles) || record.targetFiles < 0 || record.targetFiles > 200) return false;
  if (!safeInt(record.startedAtEpochMs) || record.startedAtEpochMs <= 0
    || (record.checkedAtEpochMs !== null && (!safeInt(record.checkedAtEpochMs) || record.checkedAtEpochMs < record.startedAtEpochMs))) return false;
  if (record.observedRemoteSha !== null && (!sha(record.observedRemoteSha) || !sameWidth(record.observedRemoteSha, record.candidateSha))) return false;
  if (record.candidateObservedAtEpochMs !== null && (!safeInt(record.candidateObservedAtEpochMs)
    || record.candidateObservedAtEpochMs < record.startedAtEpochMs || record.checkedAtEpochMs === null || record.candidateObservedAtEpochMs > record.checkedAtEpochMs)) return false;
  if (record.outcome === "unconfirmed") return record.observedRemoteSha === null;
  if (record.outcome === "candidateObserved") return record.observedRemoteSha === record.candidateSha && record.checkedAtEpochMs !== null && record.candidateObservedAtEpochMs !== null;
  return record.outcome === "otherHeadObserved" && record.observedRemoteSha !== null && record.observedRemoteSha !== record.candidateSha && record.checkedAtEpochMs !== null;
}

function planIdentityMatches(plan: RollbackTransactionPlan, sessionId: string, entry: ReleaseLedgerEntry) {
  return matchesEntry(plan, sessionId, entry) && plan.expectedSha === entry.expectedSha;
}

export function RollbackTransactionPanel({ gateway, sessionId, entry, enabled, disabled = false, onRecorded }: RollbackTransactionPanelProps) {
  const { t, locale } = useI18n();
  const [plan, setPlan] = useState<RollbackTransactionPlan | null>(null);
  const [busy, setBusy] = useState<"planning" | "executing" | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState<UiMessage | null>(null);
  const generation = useRef(0);
  const busyRef = useRef(false);
  const readyRef = useRef<RollbackTransactionPlan | null>(null);
  const key = entryKey(sessionId, entry);
  const usable = enabled && !disabled && Boolean(sessionId) && entry.source === "gitPush" && entry.status === "pushVerified" && entry.checkedAtEpochMs !== null && sha(entry.expectedSha);

  const discard = (candidate: RollbackTransactionPlan | null, boundSession = sessionId) => {
    if (candidate?.status === "ready" && candidate.planId) void gateway.discardRollbackTransaction(boundSession, candidate.planId).catch(() => undefined);
  };
  useEffect(() => {
    const old = readyRef.current; readyRef.current = null; discard(old); generation.current += 1; busyRef.current = false;
    setPlan(null); setBusy(null); setError(""); setMessage(null);
    return () => { const current = readyRef.current; readyRef.current = null; discard(current); generation.current += 1; busyRef.current = false; };
  }, [gateway, key, enabled, disabled]);

  const current = plan && planIdentityMatches(plan, sessionId, entry) && usable ? plan : null;
  const expired = !current || current.status !== "ready" || current.expiresAtEpochMs === null || current.expiresAtEpochMs <= Date.now();
  const canExecute = Boolean(current?.status === "ready" && current.planId && !expired && current.observedRemoteSha === current.expectedSha);

  useEffect(() => {
    if (!current || current.status !== "ready" || current.expiresAtEpochMs === null) return;
    const timer = window.setTimeout(() => { const old = readyRef.current; readyRef.current = null; discard(old); setPlan(null); setError("计划已过期，请重新准备。"); }, Math.max(0, current.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [current?.planId, current?.expiresAtEpochMs]);

  async function prepare() {
    if (!usable || busyRef.current) return;
    const old = readyRef.current; readyRef.current = null; discard(old); busyRef.current = true; const request = ++generation.current; const requestSession = sessionId;
    setBusy("planning"); setError(""); setMessage(null); setPlan(null);
    try {
      const next: unknown = await gateway.planRollbackTransaction(requestSession, entry.recordId, entry.revision);
      if (request !== generation.current) { if ((next as Partial<RollbackTransactionPlan>).status === "ready") discard(next as RollbackTransactionPlan, requestSession); return; }
      if (!validPlan(next, requestSession, entry)) {
        const invalid = next as Partial<RollbackTransactionPlan> | null;
        if (invalid?.status === "ready" && uuid(invalid.planId) && matchesEntry(invalid as RollbackTransactionPlan, requestSession, entry)) discard(invalid as RollbackTransactionPlan, requestSession);
        throw new Error("invalid response");
      }
      setPlan(next); readyRef.current = next.status === "ready" ? next : null;
    } catch { if (request === generation.current) setError("无法读取远端回滚条件，请稍后重试。"); }
    finally { if (request === generation.current) { busyRef.current = false; setBusy(null); } }
  }

  async function execute() {
    const captured = current;
    if (!usable || busyRef.current || !captured || !canExecute || !captured.planId) return;
    if (captured.expiresAtEpochMs === null || captured.expiresAtEpochMs <= Date.now()) { readyRef.current = null; discard(captured); setPlan(null); setError("计划已过期，请重新准备。"); return; }
    busyRef.current = true; const request = ++generation.current; const requestSession = sessionId; readyRef.current = null; setPlan(null); setBusy("executing"); setError(""); setMessage(null);
    try {
      // Consume the UI's local reference first. The IPC token remains valid for this
      // one execution; calling discardRollbackTransaction here would invalidate it.
      const record = await gateway.executeRollbackTransaction(requestSession, captured.planId);
      if (request !== generation.current || !validRecord(record, entry) || record.sessionId !== requestSession || record.planId !== captured.planId || record.candidateSha !== captured.candidateSha || record.parentSha !== captured.parentSha || record.sourceTreeSha !== captured.sourceTreeSha || record.targetTreeSha !== captured.targetTreeSha || record.changedPaths !== captured.changedPaths || record.targetFiles !== captured.targetFiles) throw new Error("invalid response");
      setMessage({ source: "远端恢复结果已记录：{outcome}。这只是当前观察，不能证明谁执行、合并或部署。", labels: { outcome: { source: outcome(record.outcome) } } });
    } catch { if (request === generation.current) setError("远端回滚结果未明；请读取本地恢复台账，系统不会自动重试。"); }
    finally { if (request === generation.current) { busyRef.current = false; setBusy(null); onRecorded?.(); } }
  }

  function cancel() { const old = readyRef.current; readyRef.current = null; discard(old); setPlan(null); setError(""); setMessage(null); }

  return <section className="operation-plan" aria-label={t("远端恢复事务")} aria-busy={busy !== null}>
    <h4>{t("远端恢复事务")}</h4>
    <p className="publish-muted">{t("仅已核实的 Git 推送冻结提交可用。准备会联网查询远端分支；确认会把冻结提交之前的完整父树恢复到远端并追加单父提交，不是一般冲突 revert、多提交恢复，也不承诺部署。")}</p>
    <button type="button" onClick={() => void prepare()} disabled={!usable || busy !== null}>{t("准备远端回滚计划")}</button>
    {busy === "planning" && <p role="status" className="publish-muted">{t("正在查询远端分支并核对冻结 SHA…")}</p>}
    {busy === "executing" && <p role="status" className="publish-muted">{t("正在追加远端恢复提交…")}</p>}
    {error && <p role="alert" className="publish-warning">{t(error)}</p>}{message && <p role="status">{renderUiMessage(message, t)}</p>}
    {current?.status === "blocked" && <div className="publish-warning"><p>{t("远端回滚被阻塞，当前没有可确认的计划。")}</p><p>{current.blockers.map((item) => t(blockerLabel[item] ?? "证据不完整")).join(locale === "zh-CN" ? "、" : ", ") || t("证据不完整")}</p></div>}
    {current?.status === "ready" && <div className="operation-plan"><p><strong>{t("计划已准备（一次性，最多 5 分钟）")}</strong></p><dl><dt>{t("远端")}</dt><dd>{current.remoteUrl}</dd><dt>{t("分支")}</dt><dd>{current.branch}</dd><dt>{t("冻结提交 SHA")}</dt><dd>{current.expectedSha}</dd><dt>{t("恢复来源父提交")}</dt><dd>{current.parentSha}</dd><dt>{t("源树 SHA")}</dt><dd>{current.sourceTreeSha}</dd><dt>{t("目标树 SHA")}</dt><dd>{current.targetTreeSha}</dd><dt>{t("候选 SHA")}</dt><dd>{current.candidateSha}</dd><dt>{t("观察到的远端 SHA")}</dt><dd>{current.observedRemoteSha}</dd><dt>{t("变更路径 / 目标文件")}</dt><dd>{current.changedPaths} / {current.targetFiles}</dd><dt>{t("有效期至")}</dt><dd>{when(current.expiresAtEpochMs, locale, t)}</dd></dl><p className="publish-warning">{t("确认前会清除计划；失败后请查看本地恢复台账，不能自动重试。")}</p><button type="button" onClick={() => void execute()} disabled={!canExecute || busy !== null}>{t("确认追加远端回滚提交")}</button><button type="button" onClick={cancel} disabled={busy !== null}>{t("取消远端回滚计划")}</button></div>}
  </section>;
}

const outcome = (value: RollbackRecord["outcome"]) => value === "candidateObserved" ? "当前观察到候选" : value === "otherHeadObserved" ? "当前观察到其他头" : "结果未明";
const blockerLabel: Record<string, string> = {
  remoteDifferent: "远端分支已变化", remoteUnavailable: "无法核实远端分支", priorTransaction: "已有恢复事务或未决记录",
  recordUnconfirmed: "来源推送未核实", objectsUnavailable: "本地对象不可用", rootCommit: "根提交没有父快照", mergeCommit: "合并提交不能按单父恢复",
  targetChanged: "仓库或推送目标已变化", evidenceMismatch: "来源证据不一致", previewIncomplete: "变化预览不完整",
  targetSnapshotUnsupported: "目标快照包含不支持的文件类型", targetSnapshotUnsafe: "目标路径不安全", snapshotLimit: "目标快照超出预算", noChanges: "没有可恢复的文件变化",
};

export function RollbackHistoryPanel({ gateway, sessionId, enabled, disabled = false, refreshKey, focusRecordId = null, focusRequest = 0, onObserved }: RollbackHistoryPanelProps) {
  const { t, locale } = useI18n();
  const historyRef = useRef<HTMLElement>(null);
  const [records, setRecords] = useState<RollbackRecord[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState<UiMessage | null>(null);
  const [localRefresh, setLocalRefresh] = useState(0);
  const [loaded, setLoaded] = useState<{ gateway: RollbackTransactionGateway; key: string } | null>(null);
  const generation = useRef(0);
  const busyRef = useRef(false);
  const key = JSON.stringify([sessionId, refreshKey, localRefresh, enabled, disabled]);
  const currentRecords = enabled && !disabled && loaded?.gateway === gateway && loaded.key === key ? records : null;

  useEffect(() => {
    const request = ++generation.current;
    busyRef.current = false;
    setBusy(null); setRecords(null); setLoaded(null); setError(""); setMessage(null);
    if (!enabled || disabled || !sessionId) return;
    void gateway.listRollbackRecords(sessionId).then((next) => {
      if (request !== generation.current) return;
      if (!Array.isArray(next) || next.length > 200 || next.some((item) => !validRecord(item))) throw new Error("invalid");
      if (new Set(next.map((item) => item.recordId)).size !== next.length) throw new Error("duplicate");
      setRecords(next); setLoaded({ gateway, key });
    }).catch(() => {
      if (request === generation.current) setError("无法读取本地恢复台账；读取失败不等于没有记录。");
    });
    return () => { generation.current += 1; };
  }, [gateway, key]);

  useEffect(() => {
    if (!focusRecordId || !currentRecords?.some((r) => r.recordId === focusRecordId)) return;
    const target = Array.from(historyRef.current?.querySelectorAll<HTMLElement>("article[data-record-id]") ?? [])
      .find((article) => article.dataset.recordId === focusRecordId);
    target?.scrollIntoView?.({ block: "start", behavior: "smooth" });
    target?.focus({ preventScroll: true });
  }, [currentRecords, focusRecordId, focusRequest]);

  async function verify(record: RollbackRecord) {
    if (busyRef.current || !enabled || disabled || !currentRecords?.includes(record)) return;
    busyRef.current = true;
    const request = ++generation.current;
    setBusy(record.recordId); setError(""); setMessage(null);
    try {
      const next = await gateway.verifyRollbackRecord(sessionId, record.recordId, record.revision);
      if (request !== generation.current) return;
      if (!validRecord(next) || next.recordId !== record.recordId || next.planId !== record.planId
        || next.sessionId !== record.sessionId || JSON.stringify(next.source) !== JSON.stringify(record.source)
        || next.parentSha !== record.parentSha || next.changedPaths !== record.changedPaths || next.targetFiles !== record.targetFiles
        || next.startedAtEpochMs !== record.startedAtEpochMs || next.revision !== record.revision + 1
        || next.candidateSha !== record.candidateSha || next.sourceTreeSha !== record.sourceTreeSha || next.targetTreeSha !== record.targetTreeSha
        || (record.candidateObservedAtEpochMs !== null && next.candidateObservedAtEpochMs !== record.candidateObservedAtEpochMs)) throw new Error("invalid");
      setRecords((old) => old?.map((item) => item.recordId === record.recordId ? next : item) ?? old);
      setMessage({ source: "已刷新该记录的只读远端观察；这不证明谁执行、合并或部署。" });
      onObserved?.();
    } catch {
      if (request === generation.current) setError("无法查询该远端恢复结果；不会自动重试。");
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  return <section ref={historyRef} className="operation-plan" aria-label={t("远端恢复历史")} aria-busy={busy !== null}>
    <h4>{t("远端恢复历史")}</h4>
    <p className="publish-muted">{t("以下是当前仓库的本地恢复意图和历史观察记录，不证明谁执行、合并或部署。其他头或未明结果不能证明未写入，也不授权重试。")}</p>
    <button type="button" onClick={() => { if (!busyRef.current) setLocalRefresh((value) => value + 1); }} disabled={busy !== null || !enabled || disabled}>{t("刷新本地恢复台账")}</button>
    {error && <p role="alert" className="publish-warning">{t(error)}</p>}
    {message && <p role="status">{renderUiMessage(message, t)}</p>}
    {(!enabled || disabled) ? <p className="publish-muted">{t("当前环境不可用。")}</p>
      : currentRecords === null && !error && <p role="status" className="publish-muted">{t("正在读取本地恢复台账…")}</p>}
    {currentRecords?.length === 0 && <p className="publish-muted">{t("当前仓库没有恢复记录。")}</p>}
    {currentRecords?.map((record) => <article className="operation-plan" tabIndex={-1} data-record-id={record.recordId} key={`${record.recordId}:${record.revision}`}>
      <dl>
        <dt>{t("冻结来源")}</dt><dd>{record.source.evidence.remoteUrl} / {record.source.evidence.branch}</dd>
        <dt>{t("冻结提交 SHA")}</dt><dd>{record.source.evidence.expectedSha}</dd>
        <dt>{t("候选 SHA")}</dt><dd>{record.candidateSha}</dd>
        <dt>{t("源树 / 目标树")}</dt><dd>{record.sourceTreeSha} / {record.targetTreeSha}</dd>
        <dt>{t("时间")}</dt><dd>{t("{started}（核实：{checked}）", { started: when(record.startedAtEpochMs, locale, t), checked: when(record.checkedAtEpochMs, locale, t) })}</dd>
        <dt>{t("恢复回执 ID")}</dt><dd>{record.recordId} / revision {record.revision}</dd>
        <dt>{t("来源记录 ID")}</dt><dd>{record.source.recordId} / revision {record.source.revision}</dd>
        <dt>{t("最近一次观察")}</dt><dd>{t(outcome(record.outcome))}</dd>
        <dt>{t("观察到的远端 SHA")}</dt><dd>{record.observedRemoteSha ?? t("未知")}</dd>
        <dt>{t("首次精确观察到候选")}</dt><dd>{record.candidateObservedAtEpochMs === null ? t("尚无精确候选观察") : when(record.candidateObservedAtEpochMs, locale, t)}</dd>
      </dl>
      <button type="button" onClick={() => void verify(record)} disabled={busy !== null || !enabled || disabled}>{t("只读查询远端恢复结果（核实）")}</button>
    </article>)}
  </section>;
}
