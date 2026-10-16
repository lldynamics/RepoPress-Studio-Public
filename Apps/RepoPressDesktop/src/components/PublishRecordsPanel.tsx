import { useEffect, useRef, useState } from "react";
import type { PublishRecord, PublishVerificationPlan } from "../contracts/publishLedger";
import type { RepositoryGateway } from "../contracts/repository";
import { useI18n } from "../i18n/i18n";

type PublishRecordsGateway = Pick<RepositoryGateway, "listPublishRecords" | "planPublishVerification" | "executePublishVerification" | "removePublishRecord">;

export interface PublishRecordsPanelProps {
  gateway: PublishRecordsGateway;
  sessionId: string;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
  onRecordsChanged?: () => void;
}

const genericError = "无法读取发布记录或核实结果，请稍后重试。";
const statusLabel: Record<PublishRecord["outcome"], string> = {
  unconfirmed: "未核实",
  verified: "已核实",
  different: "远端不同",
};

export function PublishRecordsPanel({ gateway, sessionId, enabled, disabled = false, refreshKey = 0, onRecordsChanged }: PublishRecordsPanelProps) {
  const { locale, t } = useI18n();
  const [records, setRecords] = useState<PublishRecord[]>([]);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [plan, setPlan] = useState<PublishVerificationPlan | null>(null);
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
    void gateway.listPublishRecords(sessionId).then((next) => {
      if (requestGeneration !== generation.current) return;
      setRecords(next);
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

  async function createPlan(record: PublishRecord) {
    if (busyRef.current || disabled || !enabled || !sessionId) return;
    busyRef.current = true;
    setBusy(true);
    setPlan(null);
    setError("");
    const requestGeneration = generation.current;
    try {
      const nextPlan = await gateway.planPublishVerification(sessionId, record.recordId);
      if (requestGeneration !== generation.current || !records.some((item) => item.recordId === record.recordId)) return;
      if (nextPlan.recordId !== record.recordId || nextPlan.remoteUrl !== record.evidence.remoteUrl || nextPlan.branch !== record.evidence.branch || nextPlan.expectedSha !== record.evidence.expectedSha) {
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
      const result = await gateway.executePublishVerification(sessionId, expectedPlan.planId);
      if (requestGeneration !== generation.current) return;
      if (result.recordId !== expectedPlan.recordId || result.evidence.remoteUrl !== expectedPlan.remoteUrl || result.evidence.branch !== expectedPlan.branch || result.evidence.expectedSha !== expectedPlan.expectedSha) {
        setError(genericError);
        return;
      }
      if (result.outcome === "verified" && result.observedRemoteSha !== expectedPlan.expectedSha) {
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
      const next = await gateway.listPublishRecords(sessionId);
      if (requestGeneration === generation.current) setRecords(next);
    } catch {
      if (requestGeneration === generation.current) { setRecords([]); setError(genericError); }
    } finally {
      if (requestGeneration === generation.current) setLoading(false);
    }
  }

  async function removeRecord(record: PublishRecord) {
    if (busyRef.current || disabled || !enabled || !sessionId || record.outcome === "unconfirmed") return;
    const message = t("确认删除本地发布记录？\n分支：{branch}\n冻结 SHA：{sha}\n仅删除本地核实记录，远端内容不会更改；不会重新推送。", { branch: record.evidence.branch, sha: record.evidence.expectedSha });
    if (!window.confirm(message)) return;
    busyRef.current = true;
    setBusy(true);
    setPlan(null);
    setError("");
    const requestGeneration = generation.current;
    try {
      const next = await gateway.removePublishRecord(sessionId, record.recordId, record.revision);
      if (requestGeneration === generation.current) setRecords(next);
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

  return <section className="publish-section" aria-label={t("发布结果记录")} aria-busy={loading || busy}>
    <div className="publish-actions"><h2>{t("发布结果记录")}</h2><button type="button" onClick={() => void refresh()} disabled={disabled || !enabled || loading || busy}>{t("刷新记录")}</button></div>
    <p className="publish-muted">{t("记录会在重启后保留，打开列表不会联网。所有仓库合计最多保留 200 条；达到上限时，可在对应仓库核实结果后删除本地记录。未核实记录不会自动清理。")}</p>
    {error && <p className="publish-warning" role="alert">{t(error)}</p>}
    {!enabled || disabled ? <p className="publish-muted">{t("当前环境不可用。")}</p> : loading ? <p className="publish-muted">{t("正在读取本地发布记录…")}</p> : records.length === 0 ? <p className="publish-muted">{t("暂无发布记录。")}</p> : <div>
      {records.map((record) => <article className="operation-plan" key={`${record.recordId}:${record.revision}`}>
        <h3>{t(record.evidence.operation === "pushRetry" ? "推送重试" : "推送")} · {t(statusLabel[record.outcome])}</h3>
        {record.outcome === "different" && <p className="publish-warning">{t("远端不同仅表示当前引用不同，不证明之前推送失败，也不会自动重推。")}</p>}
        <dl>
          <dt>{t("分支")}</dt><dd>{record.evidence.branch}</dd>
          <dt>{t("远端")}</dt><dd>{record.evidence.remoteUrl}</dd>
          <dt>{t("目标 SHA")}</dt><dd>{record.evidence.expectedSha}</dd>
          <dt>{t("开始时间")}</dt><dd>{new Date(record.startedAtEpochMs).toLocaleString(locale)}</dd>
          <dt>{t("观察到的 SHA")}</dt><dd>{record.observedRemoteSha ?? t("未知")}</dd>
          <dt>{t("核实时间")}</dt><dd>{record.checkedAtEpochMs ? new Date(record.checkedAtEpochMs).toLocaleString(locale) : t("尚未核实")}</dd>
        </dl>
        {record.evidence.changedPaths.length > 0 && <details><summary>{t("已审阅路径（{count}）", { count: record.evidence.changedPaths.length })}</summary><ul>{record.evidence.changedPaths.map((path) => <li key={path}>{path}</li>)}</ul></details>}
        <button type="button" onClick={() => void createPlan(record)} disabled={disabled || busy}>{t("核实远端结果")}</button>
        {record.outcome !== "unconfirmed" && <button type="button" onClick={() => void removeRecord(record)} disabled={disabled || busy}>{t("删除本地记录")}</button>}
        {plan?.recordId === record.recordId && <div className="operation-plan" aria-label={t("发布结果核实计划")}>
          <p>{t("将只读核实以下远端目标，不会推送或修改内容。")}</p>
          <dl><dt>{t("目标")}</dt><dd>{plan.remoteUrl} · {plan.branch}</dd><dt>{t("预期 SHA")}</dt><dd>{plan.expectedSha}</dd><dt>{t("有效期")}</dt><dd>{plan.expiresAt}</dd></dl>
          <button type="button" onClick={() => void executePlan()} disabled={disabled || busy}>{t("确认只读核实")}</button>
        </div>}
      </article>)}
    </div>}
  </section>;
}
