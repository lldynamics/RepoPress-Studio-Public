import { useLayoutEffect, useRef, useState } from "react";
import type { GitPushRetryPlan } from "../contracts/gitPushRetry";
import type { RepositoryGateway } from "../contracts/repository";
import { isGitPushRetryPlanExpired } from "../features/publish/gitPushRetryPlan";
import { useI18n } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import "./GitPushRetryPanel.css";

type State = "idle" | "loading" | "success" | "error";

export interface GitPushRetryPanelProps {
  gateway: RepositoryGateway;
  sessionId: string;
  enabled: boolean;
  disabled?: boolean;
  onSettled?: () => void;
  onCompleted?: () => Promise<void> | void;
}

export function GitPushRetryPanel({ gateway, sessionId, enabled, disabled = false, onCompleted, onSettled }: GitPushRetryPanelProps) {
  const { t } = useI18n();
  const [plan, setPlan] = useState<GitPushRetryPlan | null>(null);
  const [state, setState] = useState<State>("idle");
  const [message, setMessage] = useState<UiMessage | null>(null);
  const generation = useRef(0);
  const inFlight = useRef(false);
  const busy = state === "loading";
  const expired = plan ? isGitPushRetryPlanExpired(plan) : false;

  useLayoutEffect(() => {
    generation.current += 1;
    inFlight.current = false;
    setPlan(null); setState("idle"); setMessage(null);
    return () => { generation.current += 1; inFlight.current = false; };
  }, [gateway, sessionId, enabled, disabled]);

  async function inspect() {
    if (!enabled || disabled || inFlight.current) return;
    const current = ++generation.current;
    inFlight.current = true;
    setState("loading"); setPlan(null); setMessage(null);
    try {
      const next = await gateway.planGitPushRetry(sessionId);
      if (current !== generation.current) return;
      setPlan(next); setState("success"); setMessage({ source: "已核对实时远端状态，请审阅冻结提交和文件路径。" });
    } catch (error) {
      if (current !== generation.current) return;
      setState("error"); setMessage(messageWithLiteralError("无法生成推送重试计划：{message}", "message", error));
    } finally {
      if (current === generation.current) inFlight.current = false;
    }
  }

  async function execute() {
    if (!plan || expired || !enabled || disabled || inFlight.current) return;
    const frozenPlan = plan;
    const current = ++generation.current;
    inFlight.current = true;
    setPlan(null); setState("loading"); setMessage(null);
    try {
      const result = await gateway.executeGitPushRetry(sessionId, frozenPlan.planId);
      if (current !== generation.current) return;
      if (!result.verified
        || result.branch !== frozenPlan.branch
        || result.head !== frozenPlan.head
        || result.remoteSha !== frozenPlan.head) {
        setPlan(null); setState("error");
        setMessage({
          source: "推送结果未确认：{reason}。请重新检查远端后再决定下一步。",
          labels: { reason: { source: "远端结果未被精确确认为此计划的冻结提交" } },
        });
        return;
      }
      setPlan(null); setState("success"); setMessage({ source: "已确认远端 {branch} 精确指向 {sha}。", parameters: { branch: result.branch, sha: result.remoteSha } });
      try {
        await onCompleted?.();
      } catch {
        if (current === generation.current) {
          setMessage({ source: "已确认远端 {branch} 精确指向 {sha}；本地状态刷新失败，可稍后手动刷新。", parameters: { branch: result.branch, sha: result.remoteSha } });
        }
      }
    } catch (error) {
      if (current !== generation.current) return;
      setPlan(null); setState("error");
      setMessage(messageWithLiteralError("推送结果未确认：{reason}。请重新检查远端后再决定下一步。", "reason", error));
    } finally {
      if (current === generation.current) { inFlight.current = false; onSettled?.(); }
    }
  }

  return <section className="git-push-retry" aria-label={t("已提交内容的推送重试")} aria-busy={busy}>
    <h3>{t("已提交内容的推送重试")}</h3>
    <p>{t("仅检查已有提交。生成计划会实时读取配置的推送远端；确认后以冻结 SHA 非强制推送，并再次精确确认远端。")}</p>
    {!enabled && <p className="publish-warning">{t("当前环境未启用 Git 推送。")}</p>}
    <div className="publish-actions"><button type="button" onClick={() => void inspect()} disabled={!enabled || disabled || busy}>{t("检查可重试提交")}</button></div>
    {message && <p className={state === "error" ? "publish-warning" : "publish-muted"} role={state === "error" ? "alert" : "status"}>{renderUiMessage(message, t)}</p>}
    {plan && <div className="git-push-retry-plan">
      <h3>{t("推送重试计划")}</h3><p>{plan.summary}</p>
      <dl><dt>{t("分支")}</dt><dd>{plan.branch}</dd><dt>{t("冻结 HEAD")}</dt><dd>{plan.head}</dd><dt>{t("远端")}</dt><dd>{plan.remote} · {plan.remoteUrl}</dd><dt>{t("实时远端 SHA")}</dt><dd>{plan.observedRemoteSha}</dd><dt>{t("待推送提交")}</dt><dd>{plan.pendingCommitCount}</dd><dt>{t("变更路径")}</dt><dd>{plan.changedPaths.length}</dd></dl>
      <ul className="git-push-retry-paths" aria-label={t("待推送文件路径")}>{plan.changedPaths.map((path) => <li key={path}>{path}</li>)}</ul>
      {plan.warnings.map((warning) => <p className="publish-warning" key={warning}>{warning}</p>)}
      <p className={expired ? "publish-warning" : "publish-muted"}>{expired ? t("此重试计划已失效，请重新检查远端。") : t("计划有效至 {expiresAt}", { expiresAt: plan.expiresAt })}</p>
      <div className="publish-actions"><button type="button" className="danger-action" onClick={() => void execute()} disabled={disabled || busy || expired}>{t("确认重试推送")}</button><button type="button" onClick={() => { setPlan(null); setMessage(null); }} disabled={busy}>{t("丢弃计划")}</button></div>
    </div>}
  </section>;
}

function messageFrom(error: unknown): string | null {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null && "message" in error && typeof error.message === "string") return error.message;
  return null;
}

function messageWithLiteralError(source: string, key: string, error: unknown): UiMessage {
  const literal = messageFrom(error);
  return literal === null
    ? { source, labels: { [key]: { source: "未知错误" } } }
    : { source, parameters: { [key]: literal } };
}
