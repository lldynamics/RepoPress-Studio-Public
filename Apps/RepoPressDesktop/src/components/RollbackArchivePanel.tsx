import { useEffect, useRef, useState } from "react";
import type { RollbackArchiveGateway, RollbackArchivePlan, RollbackArchiveResult } from "../contracts/rollbackArchive";
import { useI18n } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";

export interface RollbackArchivePanelProps {
  gateway: RollbackArchiveGateway;
  sessionId: string;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
}

const MAX_RECORDS = 200;
const MAX_BYTES = 8 * 1024 * 1024;
const TTL_MS = 5 * 60 * 1000;
const MAX_TIME = 8.64e15;
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const sha256 = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const absolutePath = (value: unknown): value is string => typeof value === "string" && value.length > 0 && (value.startsWith("/") || /^[A-Za-z]:[\\/]/.test(value));
const positiveTime = (value: unknown): value is number => safeInt(value) && value > 0 && value <= MAX_TIME;
const formatTime = (value: number, locale: string) => new Date(value).toLocaleString(locale);

function validPlan(value: unknown, sessionId: string, destinationPath: string): value is RollbackArchivePlan {
  if (!value || typeof value !== "object") return false;
  const plan = value as RollbackArchivePlan;
  return uuid(plan.planId) && plan.sessionId === sessionId && absolutePath(plan.repositoryPath)
    && plan.destinationPath === destinationPath && absolutePath(plan.destinationPath) && plan.schemaVersion === 1
    && safeInt(plan.recordCount) && plan.recordCount >= 1 && plan.recordCount <= MAX_RECORDS
    && safeInt(plan.unresolvedCount) && plan.unresolvedCount >= 0
    && safeInt(plan.historicalObservationCount) && plan.historicalObservationCount >= 0
    && plan.unresolvedCount + plan.historicalObservationCount === plan.recordCount
    && safeInt(plan.byteSize) && plan.byteSize > 0 && plan.byteSize <= MAX_BYTES
    && sha256(plan.sha256) && positiveTime(plan.createdAtEpochMs) && positiveTime(plan.expiresAtEpochMs)
    && plan.createdAtEpochMs <= Date.now() && plan.expiresAtEpochMs > Date.now()
    && plan.expiresAtEpochMs - plan.createdAtEpochMs === TTL_MS;
}

function validResult(value: unknown, sessionId: string, plan: RollbackArchivePlan): value is RollbackArchiveResult {
  if (!value || typeof value !== "object") return false;
  const result = value as RollbackArchiveResult;
  return result.planId === plan.planId && result.sessionId === sessionId && result.destinationPath === plan.destinationPath
    && result.recordCount === plan.recordCount && result.byteSize === plan.byteSize && result.sha256 === plan.sha256
    && absolutePath(result.destinationPath) && safeInt(result.recordCount) && result.recordCount >= 1 && result.recordCount <= MAX_RECORDS
    && safeInt(result.byteSize) && result.byteSize > 0 && result.byteSize <= MAX_BYTES && sha256(result.sha256);
}

interface ArchiveContext {
  gateway: RollbackArchiveGateway;
  sessionId: string;
  enabled: boolean;
  disabled: boolean;
  refreshKey?: number;
}

interface BoundPlan {
  plan: RollbackArchivePlan;
  gateway: RollbackArchiveGateway;
  sessionId: string;
  destinationPath: string;
  context: ArchiveContext;
}

export function RollbackArchivePanel({ gateway, sessionId, enabled, disabled = false, refreshKey }: RollbackArchivePanelProps) {
  const { locale, t } = useI18n();
  const [destinationPath, setDestinationPath] = useState<string | null>(null);
  const [plan, setPlan] = useState<RollbackArchivePlan | null>(null);
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState<"selecting" | "planning" | "exporting" | null>(null);
  const [error, setError] = useState<UiMessage | null>(null);
  const [message, setMessage] = useState<UiMessage | null>(null);
  const generation = useRef(0);
  const busyRef = useRef(false);
  const planRef = useRef<RollbackArchivePlan | null>(null);
  const planBindingRef = useRef<BoundPlan | null>(null);
  const contextRef = useRef<ArchiveContext | null>(null);
  const contextKey = `${sessionId}\u0000${enabled}\u0000${disabled}\u0000${refreshKey ?? ""}`;
  const usable = enabled && !disabled && Boolean(sessionId);
  const context: ArchiveContext = { gateway, sessionId, enabled, disabled, refreshKey };
  contextRef.current = context;

  const sameContext = (candidate: ArchiveContext) => contextRef.current?.gateway === candidate.gateway
    && contextRef.current.sessionId === candidate.sessionId && contextRef.current.enabled === candidate.enabled
    && contextRef.current.disabled === candidate.disabled && contextRef.current.refreshKey === candidate.refreshKey;

  const discard = (candidate: RollbackArchivePlan | null, boundGateway = gateway, boundSession = sessionId) => {
    if (candidate?.planId) void boundGateway.discardRollbackArchive(boundSession, candidate.planId).catch(() => undefined);
  };

  useEffect(() => {
    const old = planRef.current;
    planRef.current = null;
    const oldBinding = planBindingRef.current;
    planBindingRef.current = null;
    discard(old, oldBinding?.gateway, oldBinding?.sessionId);
    generation.current += 1;
    busyRef.current = false;
    setDestinationPath(null);
    setPlan(null);
    setConsent(false);
    setBusy(null);
    setError(null);
    setMessage(null);
    return () => {
      const current = planRef.current;
      planRef.current = null;
      const currentBinding = planBindingRef.current;
      planBindingRef.current = null;
      discard(current, currentBinding?.gateway, currentBinding?.sessionId);
      generation.current += 1;
      busyRef.current = false;
    };
  }, [gateway, contextKey]);

  const current = usable && planRef.current === plan && planBindingRef.current?.plan === plan
    && planBindingRef.current.gateway === gateway && planBindingRef.current.sessionId === sessionId
    && planBindingRef.current.destinationPath === destinationPath && sameContext(planBindingRef.current.context)
    && plan?.destinationPath === destinationPath ? plan : null;
  const expired = !current || current.expiresAtEpochMs <= Date.now();

  useEffect(() => {
    if (!current) return;
    const timer = window.setTimeout(() => {
      if (planRef.current !== current) return;
      planRef.current = null;
      const binding = planBindingRef.current;
      planBindingRef.current = null;
      discard(current, binding?.gateway, binding?.sessionId);
      setPlan(null);
      setConsent(false);
      setError({ source: "计划已过期，请重新生成。" });
    }, Math.max(0, current.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [current?.planId, current?.expiresAtEpochMs]);

  async function selectDestination() {
    if (!usable || busyRef.current) return;
    const old = planRef.current; planRef.current = null;
    const oldBinding = planBindingRef.current; planBindingRef.current = null;
    discard(old, oldBinding?.gateway, oldBinding?.sessionId);
    setPlan(null); setConsent(false); setDestinationPath(null);
    const request = ++generation.current;
    const requestContext = context;
    busyRef.current = true;
    setBusy("selecting"); setError(null); setMessage(null);
    try {
      const selected = await gateway.selectRollbackArchiveDestination();
      if (request !== generation.current || !sameContext(requestContext) || !usable) return;
      if (selected === null) return;
      if (!absolutePath(selected)) throw new Error("invalid destination");
      setDestinationPath(selected);
    } catch {
      if (request === generation.current && sameContext(requestContext)) setError({ source: "无法选择归档目的地，请稍后重试。" });
    } finally {
      if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); }
    }
  }

  async function prepare() {
    const selected = destinationPath;
    if (!usable || busyRef.current || !selected || !absolutePath(selected)) return;
    const old = planRef.current; planRef.current = null;
    const oldBinding = planBindingRef.current; planBindingRef.current = null;
    discard(old, oldBinding?.gateway, oldBinding?.sessionId);
    setPlan(null); setConsent(false); setBusy("planning"); setError(null); setMessage(null);
    busyRef.current = true;
    const request = ++generation.current;
    const requestSession = sessionId;
    const requestContext = context;
    try {
      const next: unknown = await gateway.planRollbackArchive(requestSession, selected);
      if (request !== generation.current || !sameContext(requestContext) || !usable || destinationPath !== selected) {
        if (next && typeof next === "object" && uuid((next as Partial<RollbackArchivePlan>).planId)
          && (next as Partial<RollbackArchivePlan>).sessionId === requestSession
          && (next as Partial<RollbackArchivePlan>).destinationPath === selected) discard(next as RollbackArchivePlan, requestContext.gateway, requestSession);
        return;
      }
      if (!validPlan(next, requestSession, selected)) {
        const invalid = next && typeof next === "object" ? next as Partial<RollbackArchivePlan> : null;
        if (invalid && uuid(invalid.planId) && invalid.sessionId === requestSession && invalid.destinationPath === selected) discard(invalid as RollbackArchivePlan, requestContext.gateway, requestSession);
        throw new Error("invalid plan");
      }
      planRef.current = next; planBindingRef.current = { plan: next, gateway: requestContext.gateway, sessionId: requestSession, destinationPath: selected, context: requestContext }; setPlan(next);
    } catch (reason) {
      if (request === generation.current && sameContext(requestContext)) {
        setError((reason as { code?: string } | null)?.code === "rollback_archive_empty"
          ? { source: "当前仓库没有可归档的恢复证据。" }
          : { source: "无法生成回滚证据归档计划；目的地必须是新的绝对文件路径，不能是已有路径、仓库路径或符号链接。请稍后重试。" });
      }
    } finally {
      if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); }
    }
  }

  async function execute() {
    const captured = current;
    const capturedBinding = planBindingRef.current;
    if (!usable || disabled || busyRef.current || !captured || !capturedBinding || expired || !consent || !captured.planId || !sameContext(context) || !sameContext(capturedBinding.context)) return;
    if (captured.expiresAtEpochMs <= Date.now()) { planRef.current = null; const binding = planBindingRef.current; planBindingRef.current = null; discard(captured, binding?.gateway, binding?.sessionId); setPlan(null); setError({ source: "计划已过期，请重新生成。" }); return; }
    // Consume the one-use UI reference before invoking the gateway. Failures are terminal and cannot retry.
    planRef.current = null; planBindingRef.current = null; setPlan(null); setConsent(false); setBusy("exporting"); setError(null); setMessage(null);
    busyRef.current = true;
    const request = ++generation.current;
    const requestSession = sessionId;
    const requestContext = context;
    try {
      const result: unknown = await gateway.executeRollbackArchive(requestSession, captured.planId);
      if (request !== generation.current || !sameContext(requestContext) || !validResult(result, requestSession, captured)) throw new Error("invalid result");
      setMessage({ source: "已导出并核验本地文件：{destination}；SHA-256：{sha256}。", parameters: { destination: captured.destinationPath, sha256: captured.sha256 } });
    } catch {
      if (request === generation.current && sameContext(requestContext)) setError({ source: "归档导出结果未明；计划已消耗，不会自动重试。文件可能已存在，请检查所选文件后再选择新名称。" });
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  function cancelPlan() {
    if (busyRef.current) return;
    const old = planRef.current; planRef.current = null;
    const oldBinding = planBindingRef.current; planBindingRef.current = null;
    generation.current += 1;
    discard(old, oldBinding?.gateway, oldBinding?.sessionId);
    setPlan(null); setConsent(false); setDestinationPath(null); setError(null); setMessage(null);
  }

  return <section className="operation-plan" aria-label={t("私有回滚证据归档")} aria-busy={busy !== null}>
    <h4>{t("私有回滚证据归档")}</h4>
    <p className="publish-muted">{t("仅导出当前仓库的完整回滚台账，计划有效 5 分钟且只能执行一次；导出不会执行回滚、发布或远程写入。")}</p>
    <button type="button" onClick={() => void selectDestination()} disabled={!usable || busy !== null}>{t("选择归档目的地")}</button>
    {busy === "selecting" && <p role="status" className="publish-muted">{t("正在选择目的地…")}</p>}
    {destinationPath && <dl><dt>{t("目的地")}</dt><dd>{destinationPath}</dd></dl>}
    {destinationPath && <button type="button" onClick={() => void prepare()} disabled={!usable || busy !== null}>{t("生成归档计划")}</button>}
    {busy === "planning" && <p role="status" className="publish-muted">{t("正在统计当前仓库回滚记录…")}</p>}
    {busy === "exporting" && <p role="status" className="publish-muted">{t("正在导出并核验本地文件…")}</p>}
    {error && <p role="alert" className="publish-warning">{renderUiMessage(error, t)}</p>}
    {message && <p role="status">{renderUiMessage(message, t)}</p>}
    {current && <div className="operation-plan">
      <p><strong>{t("归档计划（一次性，最多 5 分钟）")}</strong></p>
      <dl>
        <dt>{t("仓库范围")}</dt><dd>{current.repositoryPath}</dd>
        <dt>{t("目的地")}</dt><dd>{current.destinationPath}</dd>
        <dt>{t("记录数")}</dt><dd>{current.recordCount}</dd>
        <dt>{t("未解决记录")}</dt><dd>{current.unresolvedCount}</dd>
        <dt>{t("历史观察")}</dt><dd>{current.historicalObservationCount}</dd>
        <dt>{t("大小")}</dt><dd>{t("{bytes} 字节", { bytes: current.byteSize.toLocaleString(locale) })}</dd>
        <dt>{t("SHA-256")}</dt><dd>{current.sha256}</dd>
        <dt>{t("有效期至")}</dt><dd>{formatTime(current.expiresAtEpochMs, locale)}</dd>
      </dl>
      <p className="publish-warning">{t("明文归档包含仓库路径、文件路径、远程 URL（可能包含秘密）、分支、ID、SHA 和时间。导出只复制保留台账，不会解锁未解决事务。")}</p>
      <label htmlFor="rollback-archive-consent"><input id="rollback-archive-consent" type="checkbox" checked={consent} onChange={(event) => setConsent(event.target.checked)} disabled={busy !== null || !usable} />{t("我已知悉并同意导出包含上述明文敏感信息")}</label>
      <button type="button" onClick={() => void execute()} disabled={!usable || disabled || busy !== null || !consent || expired}>{t("明确导出私有回滚证据归档")}</button>
      <button type="button" onClick={cancelPlan} disabled={busy !== null}>{t("取消归档计划")}</button>
    </div>}
  </section>;
}
