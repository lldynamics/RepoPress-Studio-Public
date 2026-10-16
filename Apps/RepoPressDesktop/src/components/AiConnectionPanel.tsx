import { useI18n } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import { useEffect, useMemo, useRef, useState } from "react";
import type { AiConnectionOperation, AiConnectionPlan, AiConnectionResult } from "../contracts/aiConnection";
import type { AiProviderRequest, RepositoryGateway } from "../contracts/repository";
import { connectionErrorLabel, connectionPlanExpired, connectionPlanMatchesRequest, connectionResultMatchesPlan, connectionWarningLabel } from "../features/ai/aiConnectionPresentation";
import "./AiConnectionPanel.css";

const MAX_MODELS = 50;

export interface AiConnectionPanelProps {
  gateway: Pick<RepositoryGateway, "planAiConnection" | "executeAiConnection">;
  config: AiProviderRequest;
  active: boolean;
  enabled: boolean;
  disabled?: boolean;
  credentialEpoch?: number;
  onSelectModel: (model: string) => void;
}

type Busy = "plan" | "execute" | null;

export function AiConnectionPanel({ gateway, config, active, enabled, disabled = false, credentialEpoch = 0, onSelectModel }: AiConnectionPanelProps) {
  const { t, locale } = useI18n();
  const [plan, setPlan] = useState<AiConnectionPlan | null>(null);
  const [result, setResult] = useState<AiConnectionResult | null>(null);
  const [busy, setBusy] = useState<Busy>(null);
  const [notice, setNotice] = useState<UiMessage | null>(null);
  const [modelFilter, setModelFilter] = useState("");
  const generation = useRef(0);
  const busyRef = useRef<Busy>(null);
  const snapshot = useMemo(() => ({ provider: config.provider, endpoint: config.endpoint.trim(), model: config.model.trim() }), [config.provider, config.endpoint, config.model]);
  const available = active && enabled && !disabled;

  useEffect(() => {
    generation.current += 1;
    busyRef.current = null;
    setPlan(null);
    setResult(null);
    setBusy(null);
    setNotice(null);
    setModelFilter("");
    return () => { generation.current += 1; busyRef.current = null; };
  }, [gateway, snapshot.provider, snapshot.endpoint, snapshot.model, active, enabled, disabled, credentialEpoch]);

  useEffect(() => {
    if (!plan) return;
    const expire = () => {
      setPlan(null);
      setNotice({ source: "连接计划已过期，请重新生成后确认。" });
    };
    if (connectionPlanExpired(plan)) { expire(); return; }
    const timer = window.setTimeout(expire, Math.min(plan.expiresAt - Date.now(), 2_147_483_647));
    return () => window.clearTimeout(timer);
  }, [plan]);

  if (!active) return null;

  async function createPlan(operation: AiConnectionOperation) {
    if (!available || busyRef.current || !snapshot.endpoint || (operation === "probe" && !snapshot.model)) return;
    const request = { ...snapshot, model: operation === "models" ? "" : snapshot.model };
    const current = generation.current;
    busyRef.current = "plan";
    setBusy("plan");
    setNotice(null);
    setPlan(null);
    setResult(null);
    try {
      const next = await gateway.planAiConnection({ operation, ...request });
      if (current !== generation.current) return;
      if (!connectionPlanMatchesRequest(next, operation, request)) {
        setNotice({ source: "返回的连接计划与当前配置不一致，请重新生成。" });
        return;
      }
      if (connectionPlanExpired(next)) {
        setNotice({ source: "连接计划已过期，请重新生成后确认。" });
        return;
      }
      setPlan(next);
      setNotice({ source: "连接计划已生成。确认前不会联系 AI 服务。" });
    } catch (error) {
      if (current === generation.current) setNotice({ source: connectionErrorLabel(error) });
    } finally {
      if (current === generation.current) { busyRef.current = null; setBusy(null); }
    }
  }

  async function executePlan() {
    if (!available || busyRef.current || !plan || connectionPlanExpired(plan)) {
      if (plan && connectionPlanExpired(plan)) {
        setPlan(null);
        setNotice({ source: "连接计划已过期，请重新生成后确认。" });
      }
      return;
    }
    const current = generation.current;
    const approvedPlan = plan;
    const approvedRequest = { operation: approvedPlan.operation, ...snapshot, model: approvedPlan.operation === "models" ? "" : snapshot.model };
    if (!connectionPlanMatchesRequest(approvedPlan, approvedRequest.operation, approvedRequest)) {
      setPlan(null);
      setNotice({ source: "服务配置已改变，请重新生成连接计划。" });
      return;
    }
    busyRef.current = "execute";
    setBusy("execute");
    // The backend consumes the plan before transport. A failure needs a new
    // review, and a second click must not replay the previous approval.
    setPlan(null);
    setResult(null);
    setNotice(null);
    try {
      const next = await gateway.executeAiConnection({ planId: approvedPlan.planId, ...approvedRequest, endpoint: approvedPlan.endpoint });
      if (current !== generation.current) return;
      if (!connectionResultMatchesPlan(next, approvedPlan)) {
        setNotice({ source: "连接结果与已确认计划不一致，未采用；请重新生成计划。" });
        return;
      }
      setResult(next);
      setPlan(null);
      setModelFilter("");
      setNotice(next.operation === "models" ? { source: "已获取服务返回的模型名称。" } : { source: "小型文本对话探测成功。" });
    } catch (error) {
      if (current === generation.current) setNotice({ source: connectionErrorLabel(error) });
    } finally {
      if (current === generation.current) { busyRef.current = null; setBusy(null); }
    }
  }

  function discardPlan() {
    if (busyRef.current) return;
    generation.current += 1;
    setPlan(null);
    setResult(null);
    setBusy(null);
    setNotice({ source: "已丢弃连接计划。" });
  }

  function selectModel(model: string) {
    if (!available || busyRef.current) return;
    generation.current += 1;
    setPlan(null);
    setResult(null);
    setBusy(null);
    setNotice({ source: "已选择模型 {model}；请重新生成连接计划。", parameters: { model } });
    onSelectModel(model);
  }

  const filteredModels = result?.operation === "models"
    ? result.models.filter((model) => model.toLocaleLowerCase().includes(modelFilter.trim().toLocaleLowerCase())).slice(0, MAX_MODELS)
    : [];
  const probeBlocked = !snapshot.model;

  return <section className="ai-connection-panel tool-subsection" aria-label={t("AI 服务连接")}>
    <strong>{t("模型与连接")}</strong>
    <p className="tool-muted">{t("模型列表只提供服务返回的名称，不推断视觉、工具调用或其他能力。连接测试只验证一次小型文本对话，不能证明全部 API 功能可用。")}</p>
    {!available && <p className="tool-warning">{t("当前状态不能进行模型发现或连接测试。")}</p>}
    <div className="tool-actions">
      <button type="button" onClick={() => void createPlan("models")} disabled={!available || !snapshot.endpoint || busy !== null}>{t("获取模型列表")}</button>
      <button type="button" onClick={() => void createPlan("probe")} disabled={!available || !snapshot.endpoint || probeBlocked || busy !== null}>{t("测试连接")}</button>
    </div>
    {probeBlocked && available && <p className="tool-muted">{t("请先手动输入模型名，或从获取到的列表中选择模型后再测试连接。")}</p>}
    {notice && <p className="tool-state" role="status">{renderUiMessage(notice, t)}</p>}
    {plan && <section className="operation-plan ai-connection-plan" aria-label={t("AI 连接确认")}>
      <h3>{plan.operation === "models" ? t("获取模型列表确认") : t("测试连接确认")}</h3>
      <dl><dt>{t("服务地址")}</dt><dd>{plan.requestUrl}</dd><dt>{t("模型")}</dt><dd>{plan.model ?? t("不适用（获取列表）")}</dd><dt>{t("请求")}</dt><dd>{plan.operation === "models" ? `GET ${plan.requestUrl}` : t("固定文本：Reply with OK.")}</dd><dt>{t("有效期")}</dt><dd>{new Date(plan.expiresAt).toLocaleTimeString(locale)}</dd></dl>
      <p>{plan.requestSummary}</p>
      {plan.operation === "models" ? <p className="tool-warning">{t("确认后会向上方服务地址发起 GET 请求以获取模型列表。")}</p> : <p className="tool-warning">{t("确认后会向上方服务地址和模型发送固定文本 “Reply with OK.”；这可能产生少量用量。")}</p>}
      <div className="tool-actions"><button type="button" className="danger-action" onClick={() => void executePlan()} disabled={!available || busy !== null || connectionPlanExpired(plan)}>{t("确认请求")}</button><button type="button" onClick={discardPlan} disabled={busy !== null}>{t("取消")}</button></div>
    </section>}
    {result?.operation === "models" && <section className="ai-connection-results" aria-label={t("模型列表")}>
      <h3>{t("服务返回的模型（最多 {count} 个）", { count: MAX_MODELS })}</h3>
      {result.models.length > MAX_MODELS && <p className="tool-warning">{t("每次最多显示 {count} 个匹配模型，可筛选其他已返回模型。", { count: MAX_MODELS })}</p>}
      <label>{t("筛选模型")}<input value={modelFilter} onChange={(event) => setModelFilter(event.target.value)} maxLength={160} disabled={busy !== null} /></label>
      {filteredModels.length ? <div className="ai-connection-models">{filteredModels.map((model) => <button type="button" key={model} onClick={() => selectModel(model)} disabled={busy !== null} title={t("选择 {model}", { model })}>{model}</button>)}</div> : <p className="tool-muted">{t("没有匹配的模型名称。")}</p>}{result.warnings.map((warning) => <p className="tool-warning" key={warning}>{t(connectionWarningLabel(warning))}</p>)}
    </section>}
    {result?.operation === "probe" && <section className="ai-connection-results" aria-label={t("连接测试结果")}><h3>{t("连接测试结果")}</h3><p className="tool-muted">{t("小型文本对话已成功完成，用时 {elapsed} ms。", { elapsed: result.elapsedMs })}</p>{result.warnings.map((warning) => <p className="tool-warning" key={warning}>{t(connectionWarningLabel(warning))}</p>)}</section>}
  </section>;
}
