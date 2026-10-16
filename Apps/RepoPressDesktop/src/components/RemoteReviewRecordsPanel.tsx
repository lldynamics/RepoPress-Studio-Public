import { useEffect, useRef, useState } from "react";
import type { RemoteReviewRecord, RemoteReviewVerificationPlan, RemoteReviewRecordsGateway } from "../contracts/remoteReviewLedger";
import { useI18n } from "../i18n/i18n";

export interface RemoteReviewRecordsPanelProps {
  gateway: RemoteReviewRecordsGateway;
  sessionId: string;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
  onRecordsChanged?: () => void;
}

const genericError = "无法读取远端审查记录或核实结果，请稍后重试。";
const outcomeLabel: Record<RemoteReviewRecord["outcome"], string> = {
  unconfirmed: "未核实",
  verified: "已核实",
};
const verificationLabel: Record<RemoteReviewRecord["verification"], string> = {
  notChecked: "尚未核实",
  matched: "匹配",
  noMatch: "未匹配（不代表未创建）",
  ambiguous: "结果不明确",
  unavailable: "暂不可用",
};

export function RemoteReviewRecordsPanel({ gateway, sessionId, enabled, disabled = false, refreshKey = 0, onRecordsChanged }: RemoteReviewRecordsPanelProps) {
  const { locale, t } = useI18n();
  const [records, setRecords] = useState<RemoteReviewRecord[]>([]);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [plan, setPlan] = useState<RemoteReviewVerificationPlan | null>(null);
  const generation = useRef(0);
  const busyRef = useRef(false);

  useEffect(() => {
    generation.current += 1;
    setPlan(null);
    setError("");
    busyRef.current = false;
    setBusy(false);
    if (!enabled || disabled || !sessionId) {
      setRecords([]);
      setLoading(false);
      return;
    }
    const requestGeneration = generation.current;
    setLoading(true);
    void gateway.listRemoteReviewRecords(sessionId).then((next) => {
      if (requestGeneration === generation.current) setRecords(next.slice(0, 200));
    }).catch(() => {
      if (requestGeneration !== generation.current) return;
      setRecords([]);
      setError(genericError);
    }).finally(() => {
      if (requestGeneration === generation.current) setLoading(false);
    });
  }, [gateway, sessionId, enabled, disabled, refreshKey]);

  useEffect(() => {
    if (!plan) return;
    const planGeneration = generation.current;
    const remaining = Date.parse(plan.expiresAt) - Date.now();
    if (!Number.isFinite(remaining) || remaining <= 0) {
      setPlan(null);
      setError("核实计划已过期，请重新生成。");
      return;
    }
    const timer = window.setTimeout(() => {
      if (planGeneration === generation.current) {
        setPlan(null);
        setError("核实计划已过期，请重新生成。");
      }
    }, remaining);
    return () => window.clearTimeout(timer);
  }, [plan]);

  function invalidatePlan(message = "") {
    generation.current += 1;
    setPlan(null);
    if (message) setError(message);
  }

  async function createPlan(record: RemoteReviewRecord) {
    if (busyRef.current || disabled || !enabled || !sessionId) return;
    busyRef.current = true;
    setBusy(true);
    setPlan(null);
    setError("");
    const requestGeneration = generation.current;
    try {
      const nextPlan = await gateway.planRemoteReviewVerification(sessionId, record.recordId);
      if (requestGeneration !== generation.current || !records.some((item) => item.recordId === record.recordId && item.revision === record.revision)) return;
      if (nextPlan.recordId !== record.recordId || nextPlan.remoteUrl !== record.evidence.remoteUrl || nextPlan.provider !== record.evidence.provider || nextPlan.owner !== record.evidence.owner || nextPlan.project !== record.evidence.project || nextPlan.sourceBranch !== record.evidence.sourceBranch || nextPlan.targetBranch !== record.evidence.targetBranch || nextPlan.sourceSha !== record.evidence.sourceSha) {
        setError(genericError);
        return;
      }
      setPlan(nextPlan);
    } catch {
      if (requestGeneration === generation.current) setError(genericError);
    } finally {
      if (requestGeneration === generation.current) {
        busyRef.current = false;
        setBusy(false);
      }
    }
  }

  async function executePlan() {
    if (busyRef.current || !plan || disabled || !enabled || !sessionId) return;
    const expiresAt = Date.parse(plan.expiresAt);
    if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
      invalidatePlan("核实计划已过期，请重新生成。");
      return;
    }
    busyRef.current = true;
    setBusy(true);
    setError("");
    const requestGeneration = generation.current;
    const expectedPlan = plan;
    setPlan(null);
    try {
      const expectedRecord = records.find((record) => record.recordId === expectedPlan.recordId);
      const result = await gateway.executeRemoteReviewVerification(sessionId, expectedPlan.planId);
      if (requestGeneration !== generation.current) return;
      const sameEvidence = expectedRecord && Object.entries(expectedRecord.evidence).every(([key, value]) => result.evidence[key as keyof typeof result.evidence] === value);
      if (!expectedRecord || !sameEvidence || !Number.isSafeInteger(result.revision) || result.revision <= expectedRecord.revision || (result.outcome === "verified") !== (result.verification === "matched")) {
        setError(genericError);
        return;
      }
      if (!expectedRecord || result.recordId !== expectedPlan.recordId || result.evidence.remoteUrl !== expectedPlan.remoteUrl || result.evidence.provider !== expectedPlan.provider || result.evidence.owner !== expectedPlan.owner || result.evidence.project !== expectedPlan.project || result.evidence.remoteProjectId !== expectedRecord.evidence.remoteProjectId || result.evidence.sourceBranch !== expectedPlan.sourceBranch || result.evidence.targetBranch !== expectedPlan.targetBranch || result.evidence.sourceSha !== expectedPlan.sourceSha || (result.outcome === "verified" && (result.verification !== "matched" || typeof result.reviewNumber !== "number" || !Number.isSafeInteger(result.reviewNumber) || result.reviewNumber <= 0))) {
        setError(genericError);
        return;
      }
      setRecords((current) => current.map((record) => record.recordId === result.recordId ? result : record));
    } catch {
      if (requestGeneration === generation.current) setError(genericError);
    } finally {
      if (requestGeneration === generation.current) {
        busyRef.current = false;
        setBusy(false);
        onRecordsChanged?.();
      }
    }
  }

  async function refresh() {
    if (busyRef.current || disabled || !enabled || !sessionId) return;
    invalidatePlan();
    setLoading(true);
    const requestGeneration = generation.current;
    try {
      const next = await gateway.listRemoteReviewRecords(sessionId);
      if (requestGeneration === generation.current) setRecords(next.slice(0, 200));
    } catch {
      if (requestGeneration === generation.current) { setRecords([]); setError(genericError); }
    } finally {
      if (requestGeneration === generation.current) setLoading(false);
    }
  }

  async function removeRecord(record: RemoteReviewRecord) {
    if (busyRef.current || disabled || !enabled || !sessionId || record.outcome !== "verified") return;
    const message = t("确认删除本地远端审查记录？\n记录 ID：{recordId}\n记录版本：{revision}\n仅删除本地记录，远端审查不会更改。", { recordId: record.recordId, revision: record.revision });
    if (!window.confirm(message)) return;
    busyRef.current = true;
    setBusy(true);
    invalidatePlan();
    setError("");
    const requestGeneration = generation.current;
    try {
      const next = await gateway.removeRemoteReviewRecord(sessionId, record.recordId, record.revision);
      if (requestGeneration === generation.current) setRecords(next.slice(0, 200));
    } catch {
      if (requestGeneration === generation.current) setError(genericError);
    } finally {
      if (requestGeneration === generation.current) {
        busyRef.current = false;
        setBusy(false);
        onRecordsChanged?.();
      }
    }
  }

  return <section className="publish-section" aria-label={t("远端审查记录")} aria-busy={loading || busy}>
    <div className="publish-actions"><h2>{t("远端审查记录")}</h2><button type="button" onClick={() => void refresh()} disabled={disabled || !enabled || loading || busy}>{t("刷新记录")}</button></div>
    <p className="publish-muted">{t("记录会在重启后保留，打开列表不会联网。所有 PR/MR 记录合计最多保留 200 条。未核实记录不会自动清理；未匹配、结果不明确或暂不可用都不证明远端审查未创建。")}</p>
    {error && <p className="publish-warning" role="alert">{t(error)}</p>}
    {!enabled || disabled ? <p className="publish-muted">{t("当前环境不可用。")}</p> : loading ? <p className="publish-muted">{t("正在读取本地远端审查记录…")}</p> : records.length === 0 ? <p className="publish-muted">{t("暂无远端审查记录。")}</p> : <div>
      {records.map((record) => <article className="operation-plan" key={`${record.recordId}:${record.revision}`}>
        <h3>{record.evidence.provider.toUpperCase()} · {t(outcomeLabel[record.outcome])}</h3>
        <dl>
          <dt>{t("所有者 / 项目")}</dt><dd>{record.evidence.owner} / {record.evidence.project}</dd>
          <dt>{t("远端项目 ID")}</dt><dd>{record.evidence.remoteProjectId}</dd>
          <dt>{t("来源 → 目标")}</dt><dd>{record.evidence.sourceBranch} → {record.evidence.targetBranch}</dd>
          <dt>{t("冻结 SHA")}</dt><dd>{record.evidence.sourceSha}</dd>
          <dt>{t("请求关联标记")}</dt><dd>{record.evidence.marker}</dd>
          <dt>{t("远端")}</dt><dd>{record.evidence.remoteUrl}</dd>
          <dt>{t("开始时间")}</dt><dd>{new Date(record.startedAtEpochMs).toLocaleString(locale)}</dd>
          <dt>{t("核实状态")}</dt><dd>{t(verificationLabel[record.verification])}</dd>
          <dt>{t("核实时间")}</dt><dd>{record.checkedAtEpochMs ? new Date(record.checkedAtEpochMs).toLocaleString(locale) : t("尚未核实")}</dd>
          {record.reviewNumber !== null && <><dt>{t("PR/MR 编号")}</dt><dd>{record.reviewNumber}</dd></>}
          {record.webUrl !== null && <><dt>{t("远端地址")}</dt><dd>{record.webUrl}</dd></>}
        </dl>
        <button type="button" onClick={() => void createPlan(record)} disabled={disabled || busy}>{t("核实远端结果")}</button>
        {record.outcome === "verified" && <button type="button" onClick={() => void removeRecord(record)} disabled={disabled || busy}>{t("删除本地记录")}</button>}
        {plan?.recordId === record.recordId && <div className="operation-plan" aria-label={t("远端审查核实计划")}>
          <p>{t("将只读核实以下远端 PR/MR，不会创建、修改或重试审查。")}</p>
          <dl><dt>{t("目标")}</dt><dd>{plan.provider} · {plan.owner}/{plan.project}</dd><dt>{t("来源 → 目标")}</dt><dd>{plan.sourceBranch} → {plan.targetBranch}</dd><dt>{t("冻结 SHA")}</dt><dd>{plan.sourceSha}</dd><dt>{t("请求关联标记")}</dt><dd>{plan.recordId}</dd><dt>{t("有效期")}</dt><dd>{plan.expiresAt}</dd></dl>
          <button type="button" onClick={() => void executePlan()} disabled={disabled || busy}>{t("确认只读核实")}</button>
        </div>}
      </article>)}
    </div>}
  </section>;
}
