import { useI18n } from "../i18n/i18n";
import type { UiTranslator } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import { useEffect, useMemo, useRef, useState } from "react";
import type {
  AiCredentialStatusSnapshot,
  AiEditPlan,
  AiEditProposal,
  AiProviderKind,
  RepositoryGateway,
} from "../contracts/repository";
import type { EditorSelectionSnapshot } from "../features/ai/selectionReplacement";
import { AiConnectionPanel } from "./AiConnectionPanel";

type BusyState = "credential" | "plan" | "execute" | "apply" | null;

export interface AIAssistantProps {
  active: boolean;
  enabled: boolean;
  isDemo: boolean;
  sessionId: string | null;
  documentId: string | null;
  documentRevision: number | null;
  selection: EditorSelectionSnapshot;
  gateway: RepositoryGateway;
  onApplyReplacement: (expectedSelection: EditorSelectionSnapshot, replacementText: string) => boolean;
}

export function AIAssistant({
  active,
  enabled,
  isDemo,
  sessionId,
  documentId,
  documentRevision,
  selection,
  gateway,
  onApplyReplacement,
}: AIAssistantProps) {
  const { t, locale } = useI18n();
  const [provider, setProvider] = useState<AiProviderKind>("ollama_local");
  const [endpoint, setEndpoint] = useState("http://127.0.0.1:11434/v1");
  const [model, setModel] = useState("");
  const [instruction, setInstruction] = useState(() => t("润色选中文本，保持原意和 Markdown 结构。"));
  const [token, setToken] = useState("");
  const [credentialEpoch, setCredentialEpoch] = useState(0);
  const [credential, setCredential] = useState<AiCredentialStatusSnapshot | null>(null);
  const [plan, setPlan] = useState<AiEditPlan | null>(null);
  const [proposals, setProposals] = useState<AiEditProposal[]>([]);
  const [acceptedIds, setAcceptedIds] = useState<Set<number>>(() => new Set());
  const [busy, setBusy] = useState<BusyState>(null);
  const [message, setMessage] = useState<UiMessage | null>(null);
  const generation = useRef(0);
  const selectedText = selection.text;
  const config = useMemo(() => ({ provider, endpoint: endpoint.trim(), model: model.trim() }), [provider, endpoint, model]);
  const credentialConfig = useMemo(() => ({ provider, endpoint: endpoint.trim(), model: "" }), [provider, endpoint]);
  const usable = active && enabled && !isDemo && Boolean(sessionId) && Boolean(documentId) && documentRevision !== null;

  useEffect(() => {
    generation.current += 1;
    setPlan(null);
    setProposals([]);
    setAcceptedIds(new Set());
    setMessage(null);
    setBusy(null);
  }, [selection.from, selection.to, selectedText, documentId, documentRevision, instruction, provider, endpoint, model, sessionId, active]);

  useEffect(() => {
    setCredential(null);
    setToken("");
    setBusy(null);
  }, [provider, endpoint]);

  useEffect(() => {
    if (!active) setToken("");
  }, [active]);

  if (!active) return null;

  function changeProvider(next: AiProviderKind) {
    setProvider(next);
    setEndpoint(next === "ollama_local" ? "http://127.0.0.1:11434/v1" : "https://api.openai.com/v1");
    setModel("");
  }

  async function inspectCredential() {
    if (!usable || provider !== "openai_compatible" || !credentialConfig.endpoint) return;
    const current = generation.current;
    setBusy("credential");
    setMessage(null);
    try {
      const status = await gateway.aiCredentialStatus(credentialConfig);
      if (current === generation.current) setCredential(status);
    } catch (error) {
      if (current === generation.current) setMessage(errorNotice("无法检查 AI 凭据：{error}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function saveCredential() {
    if (!usable || provider !== "openai_compatible" || !token || !credentialConfig.endpoint) return;
    setCredentialEpoch((current) => current + 1);
    const current = generation.current;
    const pendingToken = token;
    // Remove the secret from React state before crossing the async boundary;
    // later selection/config changes must not be able to skip this cleanup.
    setToken("");
    setBusy("credential");
    setMessage(null);
    try {
      const status = await gateway.storeAiCredential({ ...credentialConfig, token: pendingToken });
      if (current === generation.current) {
        setCredential(status);
        setMessage(status.sessionOnly ? { source: "凭据仅保存在本次进程内。" } : { source: "凭据已保存到 Linux Secret Service。" });
      }
    } catch (error) {
      if (current === generation.current) setMessage(errorNotice("无法保存 AI 凭据：{error}", error));
    } finally {
      if (current === generation.current) {
        setBusy(null);
      }
    }
  }

  async function deleteCredential() {
    if (!usable || provider !== "openai_compatible" || !credential?.configured) return;
    if (!window.confirm(t("删除此 AI 服务凭据？"))) return;
    setCredentialEpoch((current) => current + 1);
    const current = generation.current;
    setToken("");
    setBusy("credential");
    setMessage(null);
    try {
      const status = await gateway.deleteAiCredential(credentialConfig);
      if (current === generation.current) {
        setCredential(status);
        setMessage(status.warning ? { source: "本次进程内的 AI 凭据已删除；请留意密钥环提示。" } : { source: "AI 凭据已删除。" });
      }
    } catch (error) {
      if (current === generation.current) setMessage(errorNotice("无法删除 AI 凭据：{error}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function createPlan() {
    if (!usable || !sessionId || !documentId || documentRevision === null || !selectedText || !instruction.trim() || !config.endpoint || !config.model) return;
    const current = generation.current;
    setBusy("plan");
    setMessage(null);
    setPlan(null);
    setProposals([]);
    setAcceptedIds(new Set());
    try {
      const nextPlan = await gateway.planAiEdit({ sessionId, documentId, documentRevision, selectionStart: selection.from, selectionEnd: selection.to, ...config, sourceText: selectedText, instruction });
      if (current === generation.current) {
        setPlan(nextPlan);
        setMessage({ source: "计划已生成。确认前不会联系 AI 服务。" });
      }
    } catch (error) {
      if (current === generation.current) setMessage(errorNotice("无法生成 AI 计划：{error}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function executePlan() {
    if (!usable || !sessionId || !documentId || documentRevision === null || !plan || planExpired(plan)) return;
    const current = generation.current;
    const approvedPlan = plan;
    setPlan(null);
    setBusy("execute");
    setMessage(null);
    try {
      const response = await gateway.executeAiEdit({
        sessionId,
        planId: approvedPlan.planId,
        documentId,
        documentRevision,
        selectionStart: selection.from,
        selectionEnd: selection.to,
        ...config,
        sourceText: selectedText,
        instruction,
      });
      if (current === generation.current) {
        setProposals(response.proposals);
        setAcceptedIds(new Set());
        setMessage(response.proposals.length ? { source: "已收到编辑提案；请逐项选择后再应用。" } : { source: "服务未返回可应用的编辑提案。" });
      }
    } catch (error) {
      if (current === generation.current) setMessage(errorNotice("AI 请求失败：{error}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function applyAccepted() {
    if (!usable || !sessionId || !documentId || documentRevision === null || !proposals.length || acceptedIds.size === 0) return;
    const current = generation.current;
    setBusy("apply");
    setMessage(null);
    try {
      const result = await gateway.applyAiEdits({
        sessionId,
        documentId,
        documentRevision,
        selectionStart: selection.from,
        selectionEnd: selection.to,
        sourceText: selectedText,
        proposals,
        acceptedIds: [...acceptedIds],
      });
      if (current !== generation.current) return;
      if (!onApplyReplacement(selection, result.text)) {
        setProposals([]);
        setAcceptedIds(new Set());
        setMessage({ source: "编辑器选区已经变化；为避免覆盖新内容，提案未应用。请重新选择并生成计划。" });
        return;
      }
      setProposals([]);
      setAcceptedIds(new Set());
      setMessage({ source: "已应用 {count} 项到编辑缓冲区；仍需点击“保存”才会写入磁盘。", parameters: { count: result.appliedProposalIds.length } });
    } catch (error) {
      if (current === generation.current) setMessage(errorNotice("无法应用提案：{error}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  const explanation = isDemo
    ? "浏览器演示不会读取凭据、联系模型或改写编辑器。"
    : !enabled
      ? "当前环境未启用 AI 编辑。"
      : !sessionId
        ? "选择本地仓库并打开文档后才能使用 AI 编辑。"
        : !selectedText
          ? "请先在 Markdown 编辑器中选择一段非空文本。完整文档不会发送。"
          : null;

  return <section className="advanced-panel ai-assistant" aria-label={t("AI 选区编辑")}>
    <div className="advanced-heading"><div><strong>{t("AI 选区编辑")}</strong><p>{t("先计划、再发送、逐项接受；最终只修改未保存的编辑缓冲区。")}</p></div><span className="tool-badge">{t("选区")}</span></div>
    {explanation && <p className="tool-warning">{t(explanation)}</p>}
    <div className="tool-form-grid">
      <label>{t("服务类型")}<select value={provider} onChange={(event) => changeProvider(event.target.value as AiProviderKind)} disabled={!usable || busy !== null}><option value="ollama_local">{t("本机 Ollama")}</option><option value="openai_compatible">{t("外部 OpenAI-compatible")}</option></select></label>
      <label>{t("模型")}<input value={model} onChange={(event) => setModel(event.target.value)} disabled={!usable || busy !== null} maxLength={160} placeholder={provider === "ollama_local" ? t("例如 llama3.2") : t("输入服务支持的模型名")} /></label>
    </div>
    <label>{t("端点")}<input value={endpoint} onChange={(event) => setEndpoint(event.target.value)} disabled={!usable || busy !== null} spellCheck={false} /></label>
    <AiConnectionPanel gateway={gateway} config={config} active={active} enabled={enabled && !isDemo} disabled={busy !== null} credentialEpoch={credentialEpoch} onSelectModel={setModel} />
    <label>{t("编辑指令")}<textarea value={instruction} onChange={(event) => setInstruction(event.target.value)} disabled={!usable || busy !== null} maxLength={8192} /></label>
    <p className="tool-muted">{t("当前选区：{size}。服务只会收到指令和此选区。", { size: selectedText ? t("{bytes} 字节", { bytes: new Blob([selectedText]).size }) : t("无") })}</p>
    {provider === "openai_compatible" && <section className="tool-subsection" aria-label={t("AI 凭据")}>
      <p className="tool-warning">{t("外部服务必须使用 HTTPS；请求禁用代理与重定向。令牌不会显示或写入日志。")}</p>
      <div className="tool-actions"><button type="button" onClick={() => void inspectCredential()} disabled={!usable || !credentialConfig.endpoint || busy !== null}>{t("检查凭据")}</button>{credential?.configured && <button type="button" onClick={() => void deleteCredential()} disabled={busy !== null}>{t("删除凭据")}</button>}</div>
      {credential && <p className="tool-muted">{credential.configured ? t("已配置（{storage}）", { storage: credentialStorageLabel(credential, t) }) : t("尚未配置凭据")}{credential.warning ? ` · ${credentialWarningLabel(credential.warning, t)}` : ""}</p>}
      <label>{t("访问令牌")}<input type="password" autoComplete="new-password" value={token} onChange={(event) => { setToken(event.target.value); setCredentialEpoch((current) => current + 1); }} disabled={!usable || busy !== null} /></label>
      <button type="button" onClick={() => void saveCredential()} disabled={!usable || !token || !credentialConfig.endpoint || busy !== null}>{t("保存凭据")}</button>
    </section>}
    <div className="tool-actions"><button type="button" onClick={() => void createPlan()} disabled={!usable || !selectedText || !instruction.trim() || !config.endpoint || !config.model || busy !== null}>{t("生成发送计划")}</button></div>
    {message && <p className="tool-state" role="status">{renderUiMessage(message, t)}</p>}
    {plan && <section className="operation-plan"><h3>{t("AI 请求计划")}</h3><p>{plan.summary}</p><dl><dt>{t("目标")}</dt><dd>{plan.endpoint}</dd><dt>{t("模型")}</dt><dd>{plan.model}</dd><dt>{t("选区")}</dt><dd>{t("{bytes} 字节", { bytes: plan.selectionBytes })}</dd><dt>{t("指令")}</dt><dd>{t("{bytes} 字节", { bytes: plan.instructionBytes })}</dd><dt>{t("有效期")}</dt><dd>{new Date(plan.expiresAt).toLocaleTimeString(locale)}</dd></dl>{plan.warnings.map((warning) => <p className="tool-warning" key={warning}>{warning}</p>)}<div className="tool-actions"><button type="button" className="danger-action" onClick={() => void executePlan()} disabled={busy !== null || planExpired(plan)}>{t("确认并发送")}</button><button type="button" onClick={() => setPlan(null)} disabled={busy !== null}>{t("丢弃计划")}</button></div></section>}
    {proposals.length > 0 && <section className="tool-proposals"><h3>{t("编辑提案")}</h3>{proposals.map((proposal) => <label className="tool-proposal" key={proposal.id}><input type="checkbox" checked={acceptedIds.has(proposal.id)} onChange={() => setAcceptedIds((current) => toggleId(current, proposal.id))} disabled={busy !== null} /><span><small>{t("原文")}</small><code>{boundedPreview(proposal.originalText)}</code><small>{t("替换为")}</small><code>{boundedPreview(proposal.replacementText)}</code></span></label>)}<div className="tool-actions"><button type="button" className="danger-action" onClick={() => void applyAccepted()} disabled={acceptedIds.size === 0 || busy !== null}>{t("应用所选提案到缓冲区")}</button><button type="button" onClick={() => { setProposals([]); setAcceptedIds(new Set()); }} disabled={busy !== null}>{t("丢弃全部")}</button></div></section>}
  </section>;
}

function toggleId(current: Set<number>, id: number): Set<number> {
  const next = new Set(current);
  if (next.has(id)) next.delete(id); else next.add(id);
  return next;
}

function planExpired(plan: AiEditPlan): boolean {
  const expiresAt = Date.parse(plan.expiresAt);
  return !Number.isFinite(expiresAt) || expiresAt <= Date.now();
}

function boundedPreview(value: string): string {
  return value.length > 2_000 ? `${value.slice(0, 2_000)}…` : value;
}

function credentialStorageLabel(status: AiCredentialStatusSnapshot, t: UiTranslator): string {
  if (status.storage === "secret_service") return "Linux Secret Service";
  if (status.storage === "session_memory") return t("仅本次进程内存");
  return status.storage;
}

function credentialWarningLabel(warning: string, t: UiTranslator): string {
  if (warning === "secret_service_unavailable_session_only") return t("系统密钥环不可用；关闭应用后凭据会丢失");
  if (warning === "secret_service_failed_session_only_persistent_state_unverified") {
    return t("系统密钥环写入失败；本次仅保存在内存，旧持久凭据状态未能确认");
  }
  if (warning === "session_credential_deleted_persistent_state_unverified") {
    return t("本次进程内的凭据已删除，但系统密钥环不可访问，旧持久凭据状态未能确认");
  }
  return warning;
}

function errorNotice(source: string, error: unknown): UiMessage {
  const raw = error instanceof Error ? error.message : typeof error === "object" && error !== null && "message" in error && typeof error.message === "string" ? error.message : typeof error === "string" ? error : null;
  return raw === null ? { source, labels: { error: { source: "未知错误" } } } : { source, parameters: { error: raw } };
}
