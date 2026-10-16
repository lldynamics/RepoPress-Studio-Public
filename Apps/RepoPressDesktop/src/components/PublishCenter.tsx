import { RemoteReviewRecordsPanel } from "./RemoteReviewRecordsPanel";
import { ReleaseLedgerPanel } from "./ReleaseLedgerPanel";
import type { ReleaseLedgerSource, UnattributedDeploymentObservation } from "../contracts/releaseLedger";
import { PublishRecordsPanel } from "./PublishRecordsPanel";
import { useEffect, useRef, useState } from "react";
import type { AppUpdatePlan, CapabilitySnapshot, CredentialProvider, CredentialStatusSnapshot, DeploymentCheckSnapshot, GitIndexAction, GitIndexUpdatePlan, GitOperationKind, GitOperationPlan, GitStatusSnapshot, ReadinessSnapshot, RemoteReviewPlan, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { isPlanExpired, storageLabel } from "../features/publish/publishPlan";
import { indexActionEligible, indexStatusLabel } from "../features/git/indexSelection";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { canCheckAppUpdate, isAppUpdatePlanExpired, visibleAppUpdatePlan } from "../features/update/updatePlan";
import { GitPushRetryPanel } from "./GitPushRetryPanel";
import { PublishDocumentIssues, type PublishDocumentIssuesProps } from "./PublishDocumentIssues";
import { UnpublishImpactPanel } from "./UnpublishImpactPanel";

import { useI18n } from "../i18n/i18n";
import { renderUiMessage } from "../i18n/uiMessage";
import { publishExpiryMessage, publishErrorNotice, renderPublishNotice, type PublishNotice } from "../i18n/publishPresentation";

type AsyncState = "idle" | "loading" | "success" | "error";
const initialCredential = { provider: "github" as CredentialProvider, host: "github.com", account: "", username: "", token: "" };
const initialReview = { provider: "github" as CredentialProvider, host: "github.com", title: "", body: "", baseBranch: "", headBranch: "" };

export function PublishCenter({ open, onClose, repository, capabilities, gateway, onGitStatusRefresh, currentDocument, onLocateIssue }: { open: boolean; onClose: () => void; repository: RepositorySessionSnapshot | null; capabilities: CapabilitySnapshot | null; gateway: RepositoryGateway; onGitStatusRefresh?: () => Promise<void> } & PublishDocumentIssuesProps) {
  const { t } = useI18n();
  const [recordsRevision, setRecordsRevision] = useState(0);
  const [deploymentObservation, setDeploymentObservation] = useState<UnattributedDeploymentObservation | null>(null);
  const pushRecordsTarget = useRef<HTMLDivElement>(null);
  const reviewRecordsTarget = useRef<HTMLDivElement>(null);
  function openLedgerSource(source: ReleaseLedgerSource) {
    if (source === "rollback") return;
    const target = (source === "gitPush" ? pushRecordsTarget : reviewRecordsTarget).current;
    target?.scrollIntoView({ block: "start", behavior: "smooth" });
    target?.focus({ preventScroll: true });
  }
  const [credential, setCredential] = useState(initialCredential);
  const [review, setReview] = useState(initialReview);
  const [commitMessage, setCommitMessage] = useState("");
  const [credentials, setCredentials] = useState<CredentialStatusSnapshot | null>(null);
  const [deployment, setDeployment] = useState<DeploymentCheckSnapshot | null>(null);
  const [browserReadiness, setBrowserReadiness] = useState<ReadinessSnapshot | null>(null);
  const [updaterReadiness, setUpdaterReadiness] = useState<ReadinessSnapshot | null>(null);
  const [appUpdatePlan, setAppUpdatePlan] = useState<AppUpdatePlan | null>(null);
  const [gitPlan, setGitPlan] = useState<GitOperationPlan | null>(null);
  const [reviewPlan, setReviewPlan] = useState<RemoteReviewPlan | null>(null);
  const [gitStatus, setGitStatus] = useState<GitStatusSnapshot | null>(null);
  const [indexAction, setIndexAction] = useState<GitIndexAction>("stage");
  const [selectedPaths, setSelectedPaths] = useState<string[]>([]);
  const [indexPlan, setIndexPlan] = useState<GitIndexUpdatePlan | null>(null);
  const [loadState, setLoadState] = useState<AsyncState>("idle");
  const [actionState, setActionState] = useState<AsyncState>("idle");
  const [message, setMessage] = useState<PublishNotice | null>(null);
  const generation = useRef(0);
  const gitExecutionInFlight = useRef(false);
  const reviewExecutionInFlight = useRef(false);
  const drawer = useRef<HTMLElement>(null);
  const sessionId = repository?.sessionId;
  const isDemo = !capabilities?.localEdit;
  useDrawerFocus(open, drawer, onClose);

  useEffect(() => {
    const current = ++generation.current;
    setCredential(initialCredential); setReview(initialReview); setCommitMessage(""); setGitPlan(null); setReviewPlan(null); setIndexPlan(null); setGitStatus(null); setSelectedPaths([]); setMessage(null); setActionState("idle");
    setCredentials(null); setDeployment(null); setDeploymentObservation(null); setBrowserReadiness(null); setUpdaterReadiness(null); setAppUpdatePlan(null);
    if (!open) {
      setLoadState("idle");
      return () => { generation.current += 1; };
    }
    if (!sessionId) {
      setLoadState("loading");
      void gateway.updateReadiness().then((snapshot) => { if (current === generation.current) { setUpdaterReadiness(snapshot); setLoadState("success"); } }).catch((error) => { if (current === generation.current) { setLoadState("error"); setMessage(publishErrorNotice("无法读取更新器状态：{error}", error)); } });
      return () => { generation.current += 1; };
    }
    setLoadState("loading");
    const gitStatusRequest = capabilities?.gitStatus && repository?.isGitRepository
      ? gateway.gitStatus(sessionId)
      : Promise.resolve<GitStatusSnapshot | null>(null);
    void Promise.all([gateway.credentialStatus(sessionId), gateway.browserProtocolStatus(sessionId), gateway.updateReadiness(), gitStatusRequest])
      .then(([credentialSnapshot, browserSnapshot, updaterSnapshot, status]) => {
        if (current !== generation.current) return;
        setCredentials(credentialSnapshot); setDeployment({ configured: false, provider: null, status: "not_checked", url: null, summary: "点击“检查部署状态”后才会联系远端服务。", checkedAt: null, warning: null }); setBrowserReadiness(browserSnapshot); setUpdaterReadiness(updaterSnapshot); setGitStatus(status); setLoadState("success");
      })
      .catch((error) => { if (current === generation.current) { setLoadState("error"); setMessage(publishErrorNotice("无法读取发布状态：{error}", error)); } });
    return () => { generation.current += 1; };
  }, [capabilities?.gitStatus, gateway, open, repository?.isGitRepository, sessionId]);

  const eligibleFiles = gitStatus?.changedFiles.filter((file) => indexActionEligible(file, indexAction)) ?? [];
  function togglePath(path: string) { setSelectedPaths((current) => current.includes(path) ? current.filter((item) => item !== path) : [...current, path]); }
  async function planIndexUpdate() {
    if (!sessionId || isDemo || !capabilities?.gitIndex || !selectedPaths.length) return;
    const current = generation.current; setActionState("loading"); setMessage(null); setIndexPlan(null);
    try { const plan = await gateway.planGitIndexUpdate({ sessionId, action: indexAction, paths: selectedPaths }); if (current === generation.current) { setIndexPlan(plan); setActionState("success"); setMessage({ source: "已生成暂存区计划，请核对路径后确认执行。" }); } }
    catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("无法生成暂存区计划：{error}", error)); } }
  }
  async function executeIndexPlan() {
    if (!sessionId || !indexPlan || isPlanExpired(indexPlan) || isDemo) return;
    const current = generation.current; setActionState("loading"); setMessage(null);
    try { const result = await gateway.executeGitIndexUpdate({ sessionId, planId: indexPlan.planId }); if (current === generation.current) { setIndexPlan(null); setSelectedPaths([]); setActionState("success"); setMessage({ source: "{action}已完成：{summary}", parameters: { summary: result.summary }, labels: { action: { source: result.action === "stage" ? "暂存" : "取消暂存" } } }); await onGitStatusRefresh?.(); if (current !== generation.current) return; const status = await gateway.gitStatus(sessionId); if (current === generation.current) setGitStatus(status); } }
    catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("执行暂存区计划失败：{error}", error)); } }
  }

  function canPlan(operation: GitOperationKind): boolean {
    return Boolean(sessionId && repository?.isGitRepository && !isDemo && (operation === "commit" ? capabilities?.gitCommit : operation === "fetch" ? capabilities?.gitFetch : capabilities?.gitPush));
  }
  async function planGit(operation: GitOperationKind) {
    if (!sessionId || !canPlan(operation) || (operation === "commit" && !commitMessage.trim())) return;
    const current = generation.current; setActionState("loading"); setMessage(null); setGitPlan(null);
    try {
      const plan = await gateway.planGitOperation({ sessionId, operation, commitMessage: operation === "commit" ? commitMessage.trim() : null });
      if (current === generation.current) { setGitPlan(plan); setActionState("success"); setMessage({ source: "已生成操作计划。请核对内容后明确确认执行。" }); }
    } catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("无法生成计划：{error}", error)); } }
  }
  async function executeGitPlan() {
    if (!sessionId || !gitPlan || isPlanExpired(gitPlan) || isDemo || gitExecutionInFlight.current) return;
    gitExecutionInFlight.current = true;
    const frozen = gitPlan; setGitPlan(null);
    const current = generation.current; setActionState("loading"); setMessage(null);
    try {
      const result = await gateway.executeGitOperation({ sessionId, planId: frozen.planId });
      if (current === generation.current) { setGitPlan(null); setActionState("success"); setMessage({ source: "{action}已完成：{summary}", parameters: { action: gitOperationLabel(result.operation), summary: result.summary } }); }
    } catch (error) { if (current === generation.current) { setActionState("error"); setMessage(frozen.operation === "push" ? { source: "推送结果尚未确认。请查看执行记录并只读核实远端，避免直接重复推送。" } : publishErrorNotice("执行失败：{error}", error)); } }
    finally { gitExecutionInFlight.current = false; setRecordsRevision((value) => value + 1); }
  }
  async function saveCredential() {
    if (!sessionId || isDemo || !capabilities?.remoteAuth || !credential.host.trim() || !credential.token) return;
    const current = generation.current; setActionState("loading"); setMessage(null);
    try {
      const status = await gateway.storeRepositoryCredential({ sessionId, provider: credential.provider, host: credential.host.trim(), account: nullable(credential.account), username: nullable(credential.username), token: credential.token });
      if (current === generation.current) { setCredentials(status); setCredential(initialCredential); setActionState("success"); setMessage({ source: "凭据已保存到{storage}；令牌未被保留在界面中。", labels: { storage: { source: storageLabel(status.storage) } } }); }
    } catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("无法保存凭据：{error}", error)); } }
    finally { if (current === generation.current) setCredential((value) => ({ ...value, token: "" })); }
  }
  async function deleteCredential(credentialId: string) {
    if (!sessionId || isDemo || !capabilities?.remoteAuth || !window.confirm(t("删除此凭据？此操作不会影响远端仓库。"))) return;
    const current = generation.current; setActionState("loading"); setMessage(null);
    try {
      const status = await gateway.deleteRepositoryCredential({ sessionId, credentialId });
      if (current === generation.current) { setCredentials(status); setActionState("success"); setMessage({ source: "凭据已删除。" }); }
    } catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("无法删除凭据：{error}", error)); } }
  }
  async function planReview() {
    if (!sessionId || isDemo || !capabilities?.remoteAuth || !review.host.trim() || !review.title.trim()) return;
    const current = generation.current; setActionState("loading"); setMessage(null); setReviewPlan(null);
    try {
      const plan = await gateway.planRemoteReview({ sessionId, provider: review.provider, host: review.host.trim(), title: review.title.trim(), body: nullable(review.body), baseBranch: nullable(review.baseBranch), headBranch: nullable(review.headBranch) });
      if (current === generation.current) { setReviewPlan(plan); setActionState("success"); setMessage({ source: "已生成 PR/MR 计划。确认前不会创建远端审阅。 " }); }
    } catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("无法生成 PR/MR 计划：{error}", error)); } }
  }
  async function executeReviewPlan() {
    if (!sessionId || !reviewPlan || isPlanExpired(reviewPlan) || isDemo || reviewExecutionInFlight.current) return;
    reviewExecutionInFlight.current = true;
    const frozenPlan = reviewPlan; setReviewPlan(null);
    const current = generation.current; setActionState("loading"); setMessage(null);
    try {
      const result = await gateway.executeRemoteReview({ sessionId, planId: frozenPlan.planId });
      if (current === generation.current) { setReviewPlan(null); setActionState("success"); setMessage({ source: "{summary}{url}", parameters: { summary: result.summary, url: result.url ? `：${result.url}` : "" } }); }
    } catch (error) { if (current === generation.current) { setActionState("error"); setMessage({ source: "PR/MR 创建结果尚未核实。请查看执行记录并只读核实，避免重复创建；若未产生记录，请重新检查凭据、来源提交和本地存储。" }); } }
    finally { reviewExecutionInFlight.current = false; setRecordsRevision((value) => value + 1); }
  }
  async function refreshDeployment() {
    if (!sessionId) return;
    const current = generation.current; setActionState("loading"); setMessage(null);
    try { const snapshot = await gateway.checkDeployment(sessionId); if (current === generation.current) { setDeployment(snapshot); setDeploymentObservation({ sessionId, snapshot }); setActionState("success"); setMessage({ source: "部署状态已只读刷新。" }); } }
    catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("无法检查部署：{error}", error)); } }
  }
  async function checkAppUpdate() {
    if (!canCheckAppUpdate(updaterReadiness, isDemo) || actionState === "loading") return;
    const current = ++generation.current; setActionState("loading"); setMessage(null); setAppUpdatePlan(null);
    try {
      const result = await gateway.checkAppUpdate();
      if (current === generation.current) { setAppUpdatePlan(visibleAppUpdatePlan(result)); setActionState("success"); setMessage({ source: "{summary}", parameters: { summary: result.summary } }); }
    } catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("无法检查 AppImage 更新：{error}", error)); } }
  }
  async function installAppUpdate() {
    if (!appUpdatePlan || isAppUpdatePlanExpired(appUpdatePlan) || actionState === "loading" || isDemo) return;
    const planId = appUpdatePlan.planId; const current = generation.current; setAppUpdatePlan(null); setActionState("loading"); setMessage(null);
    try {
      const result = await gateway.installAppUpdate(planId);
      if (current === generation.current) { setActionState(result.installed ? "success" : "error"); setMessage(result.installed && result.requiresRestart ? { source: "已验证并替换，需手动重启。" } : { source: "{summary}", parameters: { summary: result.summary } }); }
    } catch (error) { if (current === generation.current) { setActionState("error"); setMessage(publishErrorNotice("安装 AppImage 更新失败：{error}", error)); } }
  }

  return <aside ref={drawer} className={open ? "publish-center open" : "publish-center"} role="dialog" aria-modal="true" aria-labelledby="publish-center-title" aria-hidden={!open} inert={!open} tabIndex={-1}>
    <div className="publish-header"><div><h1 id="publish-center-title">{t("发布中心")}</h1><p>{t("所有写操作均先生成计划，再明确确认。")}</p></div><button type="button" className="publish-close" onClick={onClose} aria-label={t("关闭发布中心")}>×</button></div>
    <div className="publish-content">
    {!repository && <p className="publish-empty">{t("选择一个本地仓库后可检查发布能力；桌面集成仍可查看。")}</p>}
    {message && <p className={`publish-state ${actionState === "error" || loadState === "error" ? "error" : ""}`} role={actionState === "error" || loadState === "error" ? "alert" : "status"}>{renderPublishNotice(message, t)}</p>}
    {loadState === "loading" && <p className="publish-state" role="status">{t("正在读取发布状态…")}</p>}
    <section className="publish-section desktop-update-section"><h2>{t("桌面集成")}</h2>{repository && <ReadinessRow label="浏览器协议" snapshot={browserReadiness} />}<ReadinessRow label="签名更新产物" snapshot={updaterReadiness} />
      <div className="update-card" aria-label={t("AppImage 更新")}><h3>{t("AppImage 更新")}</h3><p className="publish-muted">{t("仅在你点击检查后读取签名更新候选；二次确认安装后仍需手动重启应用。")}</p>
        {!isDemo && updaterReadiness && !canCheckAppUpdate(updaterReadiness, false) && <p className="publish-warning">{t("当前安装包不支持应用内更新，或此构建尚未配置更新端点与公钥；不会尝试联网。")}</p>}
        {isDemo && <p className="publish-warning">{t("浏览器演示不检查或安装更新。")}</p>}
        <button type="button" onClick={() => void checkAppUpdate()} disabled={!canCheckAppUpdate(updaterReadiness, isDemo) || actionState === "loading"}>{canCheckAppUpdate(updaterReadiness, isDemo) ? t("检查 AppImage 更新") : t("应用内更新未启用")}</button>
        {appUpdatePlan && <AppUpdatePlanCard plan={appUpdatePlan} disabled={actionState === "loading"} onConfirm={() => void installAppUpdate()} onDiscard={() => setAppUpdatePlan(null)} />}
      </div>
    </section>
    {repository && <>
      {open && <PublishDocumentIssues key={sessionId} currentDocument={currentDocument} onLocateIssue={onLocateIssue} />}
      {open && <UnpublishImpactPanel key={`impact:${sessionId}`} enabled={Boolean(!isDemo && capabilities?.contentHealth)} sessionId={sessionId ?? null} gateway={gateway} currentDocument={currentDocument ?? null} onLocateIssue={onLocateIssue} />}
      {isDemo && <p className="publish-warning">{t("浏览器演示只显示只读状态；不会保存凭据、生成或执行发布计划。")}</p>}
      <ReleaseLedgerPanel archiveGateway={gateway} gateway={gateway} rollbackGateway={gateway} previewGateway={gateway} candidateGateway={gateway} transactionGateway={gateway} sessionId={repository.sessionId} enabled={Boolean(open && !isDemo && repository.isGitRepository)} disabled={actionState === "loading"} refreshKey={recordsRevision} deployment={deploymentObservation} onOpenSource={openLedgerSource} />
      <section className="publish-section"><h2>{t("Git 操作")}</h2><p className="publish-muted">{t("Commit：{commit} · Fetch：{fetch} · Push：{push}", { commit: t(capabilities?.gitCommit ? "可计划" : "不可用"), fetch: t(capabilities?.gitFetch ? "可计划" : "不可用"), push: t(capabilities?.gitPush ? "可计划" : "不可用") })}</p>
        <label>{t("提交说明")}<input value={commitMessage} onChange={(event) => setCommitMessage(event.target.value)} disabled={!canPlan("commit") || actionState === "loading"} placeholder={t("例如：docs: 发布更新")} /></label>
        <div className="publish-actions"><button type="button" onClick={() => void planGit("commit")} disabled={!canPlan("commit") || !commitMessage.trim() || actionState === "loading"}>{t("生成 Commit 计划")}</button><button type="button" onClick={() => void planGit("fetch")} disabled={!canPlan("fetch") || actionState === "loading"}>{t("生成 Fetch 计划")}</button><button type="button" onClick={() => void planGit("push")} disabled={!canPlan("push") || actionState === "loading"}>{t("生成 Push 计划")}</button></div>
        {gitPlan && <GitPlanCard plan={gitPlan} disabled={actionState === "loading" || isDemo} onConfirm={() => void executeGitPlan()} onDiscard={() => setGitPlan(null)} />}
        <div ref={pushRecordsTarget} tabIndex={-1} aria-label={t("推送记录入口")}><PublishRecordsPanel gateway={gateway} sessionId={repository.sessionId} enabled={Boolean(open && !isDemo && repository.isGitRepository)} disabled={actionState === "loading"} refreshKey={recordsRevision} onRecordsChanged={() => setRecordsRevision((value) => value + 1)} /></div>
        <GitPushRetryPanel gateway={gateway} sessionId={repository.sessionId} enabled={Boolean(open && !isDemo && repository.isGitRepository && capabilities?.gitPush)} disabled={!open || actionState === "loading"} onSettled={() => setRecordsRevision((value) => value + 1)} onCompleted={async () => { const current = generation.current; await onGitStatusRefresh?.(); if (current !== generation.current) return; const status = await gateway.gitStatus(repository.sessionId); if (current === generation.current) setGitStatus(status); }} />
      </section>
      <section className="publish-section" aria-labelledby="git-index-heading"><h2 id="git-index-heading">{t("暂存区选择")}</h2><p className="publish-muted">{t("逐项选择要暂存或取消暂存的文件；其他文件保持不动。")}</p>
        <div className="index-mode" role="group" aria-label={t("暂存区动作")}><button type="button" aria-pressed={indexAction === "stage"} onClick={() => { setIndexAction("stage"); setSelectedPaths([]); setIndexPlan(null); }}>{t("暂存文件")}</button><button type="button" aria-pressed={indexAction === "unstage"} onClick={() => { setIndexAction("unstage"); setSelectedPaths([]); setIndexPlan(null); }}>{t("取消暂存")}</button></div>
        {!capabilities?.gitIndex && <p className="publish-warning">{t("当前桌面后端未提供暂存区操作。")}</p>}
        {eligibleFiles.length === 0 ? <p className="publish-muted">{t(indexAction === "stage" ? "没有可暂存的文件。" : "没有可取消暂存的文件。")}</p> : <div className="index-files" role="group" aria-label={t(indexAction === "stage" ? "可暂存的文件" : "可取消暂存的文件")}>{eligibleFiles.map((file) => <label className="index-file" key={file.relativePath}><input type="checkbox" checked={selectedPaths.includes(file.relativePath)} onChange={() => togglePath(file.relativePath)} disabled={isDemo || !capabilities?.gitIndex || actionState === "loading"} /><span><strong>{file.relativePath}</strong><small>{t(indexStatusLabel(file.status))}</small></span></label>)}</div>}
        <button type="button" onClick={() => void planIndexUpdate()} disabled={isDemo || !capabilities?.gitIndex || !selectedPaths.length || actionState === "loading"}>{t(indexAction === "stage" ? "生成暂存计划" : "生成取消暂存计划")}</button>
        {indexPlan && <IndexPlanCard plan={indexPlan} disabled={actionState === "loading" || isDemo} onConfirm={() => void executeIndexPlan()} onDiscard={() => setIndexPlan(null)} />}
      </section>
      <section className="publish-section"><h2>{t("凭据")}</h2><p className="publish-muted">{t("存储：{storage}。令牌不可回读，也不会显示或写入日志。", { storage: credentials ? t(storageLabel(credentials.storage)) : t("正在检查") })}</p>
        {credentials?.warning && <p className="publish-warning">{credentials.warning}</p>}
        {credentials?.credentials.map((item) => <div className="credential-row" key={item.credentialId}><span>{item.provider} · {item.host}{item.account ? ` / ${item.account}` : ""} · {t(storageLabel(item.storage))}</span><button type="button" onClick={() => void deleteCredential(item.credentialId)} disabled={isDemo || !capabilities?.remoteAuth || actionState === "loading"}>{t("删除")}</button></div>)}
        <div className="publish-form-grid"><label>{t("平台")}<select value={credential.provider} onChange={(event) => setCredential((value) => ({ ...value, provider: event.target.value as CredentialProvider, host: event.target.value === "github" ? "github.com" : "gitlab.com" }))} disabled={isDemo || !capabilities?.remoteAuth}><option value="github">GitHub</option><option value="gitlab">GitLab</option></select></label><label>Host<input value={credential.host} onChange={(event) => setCredential((value) => ({ ...value, host: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label><label>{t("账户（可选）")}<input value={credential.account} onChange={(event) => setCredential((value) => ({ ...value, account: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label><label>{t("用户名（可选）")}<input value={credential.username} onChange={(event) => setCredential((value) => ({ ...value, username: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label></div>
        <label>{t("访问令牌")}<input type="password" autoComplete="new-password" value={credential.token} onChange={(event) => setCredential((value) => ({ ...value, token: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label><button type="button" onClick={() => void saveCredential()} disabled={isDemo || !capabilities?.remoteAuth || !credential.host.trim() || !credential.token || actionState === "loading"}>{t("保存凭据")}</button>
      </section>
      <section className="publish-section"><h2>PR / MR</h2><p className="publish-muted">{t("必须先计划；不会因填写表单而创建远端审阅。")}</p><div className="publish-form-grid"><label>{t("平台")}<select value={review.provider} onChange={(event) => setReview((value) => ({ ...value, provider: event.target.value as CredentialProvider, host: event.target.value === "github" ? "github.com" : "gitlab.com" }))} disabled={isDemo || !capabilities?.remoteAuth}><option value="github">GitHub PR</option><option value="gitlab">GitLab MR</option></select></label><label>Host<input value={review.host} onChange={(event) => setReview((value) => ({ ...value, host: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label><label>{t("目标分支（可选）")}<input value={review.baseBranch} onChange={(event) => setReview((value) => ({ ...value, baseBranch: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label><label>{t("来源分支（可选）")}<input value={review.headBranch} onChange={(event) => setReview((value) => ({ ...value, headBranch: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label></div><label>{t("标题")}<input value={review.title} onChange={(event) => setReview((value) => ({ ...value, title: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label><label>{t("说明（可选）")}<textarea value={review.body} onChange={(event) => setReview((value) => ({ ...value, body: event.target.value }))} disabled={isDemo || !capabilities?.remoteAuth} /></label><button type="button" onClick={() => void planReview()} disabled={isDemo || !capabilities?.remoteAuth || !review.host.trim() || !review.title.trim() || actionState === "loading"}>{t("生成 PR/MR 计划")}</button>{reviewPlan && <ReviewPlanCard plan={reviewPlan} disabled={actionState === "loading" || isDemo} onConfirm={() => void executeReviewPlan()} onDiscard={() => setReviewPlan(null)} />}</section>
      <div ref={reviewRecordsTarget} tabIndex={-1} aria-label={t("PR/MR 记录入口")}><RemoteReviewRecordsPanel gateway={gateway} sessionId={repository.sessionId} enabled={Boolean(open && !isDemo && repository.isGitRepository)} disabled={actionState === "loading"} refreshKey={recordsRevision} onRecordsChanged={() => setRecordsRevision((value) => value + 1)} /></div>
      <section className="publish-section"><h2>{t("部署（只读）")}</h2><p>{deployment ? deploymentObservation ? deployment.summary : t("点击“检查部署状态”后才会联系远端服务。") : t("尚未检查")}</p>{deployment?.url && <a href={deployment.url} target="_blank" rel="noreferrer">{t("查看部署地址")}</a>}{deployment?.warning && <p className="publish-warning">{deployment.warning}</p>}<button type="button" onClick={() => void refreshDeployment()} disabled={!sessionId || actionState === "loading"}>{t("检查部署状态")}</button></section>
    </>}
    </div>
  </aside>;
}

function IndexPlanCard({ plan, disabled, onConfirm, onDiscard }: { plan: GitIndexUpdatePlan; disabled: boolean; onConfirm: () => void; onDiscard: () => void }) { const { t, locale } = useI18n(); const expired = isPlanExpired(plan); return <div className="operation-plan"><h3>{t(plan.action === "stage" ? "暂存计划" : "取消暂存计划")}</h3><p>{plan.summary}</p><p className="publish-muted">{t("路径：{paths}", { paths: plan.paths.join("、") })}</p>{plan.warnings.map((warning) => <p className="publish-warning" key={warning}>{warning}</p>)}<p className={expired ? "publish-warning" : "publish-muted"}>{renderUiMessage(publishExpiryMessage(plan.expiresAt, locale), t)}</p><div className="publish-actions"><button type="button" className="danger-action" disabled={disabled || expired} onClick={onConfirm}>{t("确认执行")}</button><button type="button" onClick={onDiscard} disabled={disabled}>{t("丢弃计划")}</button></div></div>; }
function GitPlanCard({ plan, disabled, onConfirm, onDiscard }: { plan: GitOperationPlan; disabled: boolean; onConfirm: () => void; onDiscard: () => void }) {
  const { t, locale } = useI18n(); const expired = isPlanExpired(plan);
  const missingDestination = plan.operation === "push" && !plan.remoteUrl;
  return <div className="operation-plan"><h3>{t("{operation} 计划", { operation: gitOperationLabel(plan.operation) })}</h3><p>{plan.summary}</p>
    <dl><dt>{t("分支")}</dt><dd>{plan.branch ?? t("未检测到")}</dd><dt>HEAD</dt><dd>{plan.head ?? t("未检测到")}</dd><dt>{t("远端")}</dt><dd>{plan.remote ?? t("未配置")}</dd>
      {plan.operation === "push" && <><dt>{t("实际推送地址")}</dt><dd>{plan.remoteUrl ?? t("缺少地址，请重新生成计划")}</dd></>}
      <dt>{t("已暂存文件")}</dt><dd>{plan.stagedFiles.length ? plan.stagedFiles.join("、") : t("无")}</dd></dl>
    {plan.warnings.map((warning) => <p className="publish-warning" key={warning}>{warning}</p>)}
    <p className={expired ? "publish-warning" : "publish-muted"}>{renderUiMessage(publishExpiryMessage(plan.expiresAt, locale), t)}</p>
    <div className="publish-actions"><button type="button" className="danger-action" disabled={disabled || expired || missingDestination} onClick={onConfirm}>{t("确认执行 {operation}", { operation: gitOperationLabel(plan.operation) })}</button><button type="button" onClick={onDiscard} disabled={disabled}>{t("丢弃计划")}</button></div>
  </div>;
}
function ReviewPlanCard({ plan, disabled, onConfirm, onDiscard }: { plan: RemoteReviewPlan; disabled: boolean; onConfirm: () => void; onDiscard: () => void }) { const { t, locale } = useI18n(); const expired = isPlanExpired(plan); return <div className="operation-plan"><h3>{t("{kind} 计划", { kind: plan.provider === "github" ? "PR" : "MR" })}</h3><p>{plan.summary}</p><dl><dt>{t("标题")}</dt><dd>{plan.title}</dd><dt>{t("分支")}</dt><dd>{plan.headBranch ?? t("当前分支")} → {plan.baseBranch ?? t("默认分支")}</dd><dt>Host</dt><dd>{plan.host}</dd><dt>{t("冻结来源 SHA")}</dt><dd>{plan.sourceSha}</dd><dt>{t("关联标记")}</dt><dd>{plan.requestMarker}</dd></dl><details><summary>{t("实际发送的说明")}</summary><pre>{plan.bodyPreview}</pre></details>{plan.warnings.map((warning) => <p className="publish-warning" key={warning}>{warning}</p>)}<p className={expired ? "publish-warning" : "publish-muted"}>{renderUiMessage(publishExpiryMessage(plan.expiresAt, locale), t)}</p><div className="publish-actions"><button type="button" className="danger-action" disabled={disabled || expired} onClick={onConfirm}>{t("确认创建")}</button><button type="button" onClick={onDiscard} disabled={disabled}>{t("丢弃计划")}</button></div></div>; }
function AppUpdatePlanCard({ plan, disabled, onConfirm, onDiscard }: { plan: AppUpdatePlan; disabled: boolean; onConfirm: () => void; onDiscard: () => void }) {
  const { t } = useI18n(); const expired = isAppUpdatePlanExpired(plan);
  return <div className="operation-plan update-plan"><h3>{t("更新候选：{current} → {version}", { current: plan.currentVersion, version: plan.version })}</h3>
    <dl><dt>{t("发布时间")}</dt><dd>{plan.publishedAt ?? t("未知")}</dd><dt>{t("下载 Host")}</dt><dd>{plan.downloadHost}</dd><dt>{t("产物")}</dt><dd>{plan.artifactName}</dd><dt>{t("过期时间")}</dt><dd>{plan.expiresAt}</dd></dl>
    {plan.notes && <p><strong>{t("发布说明：")}</strong>{plan.notes}</p>}
    {plan.warnings.map((warning) => <p className="publish-warning" key={warning}>{warning}</p>)}
    {expired && <p className="publish-warning">{t("此更新候选已过期，请重新检查。")}</p>}
    <div className="publish-actions"><button type="button" className="danger-action" disabled={disabled || expired} onClick={onConfirm}>{t("确认安装此更新")}</button><button type="button" onClick={onDiscard} disabled={disabled}>{t("丢弃候选")}</button></div>
  </div>;
}
function ReadinessRow({ label, snapshot }: { label: string; snapshot: ReadinessSnapshot | null }) { const { t } = useI18n(); return <p className="readiness-row"><strong>{t(label)}</strong>：{snapshot ? (snapshot.ready ? t("就绪") : snapshot.configured ? t("未就绪") : t("未配置")) : t("正在检查")}{snapshot?.summary ? ` — ${snapshot.summary}` : ""}{snapshot?.warning && snapshot.warning !== snapshot.summary ? <span className="publish-warning"> {snapshot.warning}</span> : null}</p>; }
function gitOperationLabel(operation: GitOperationKind) { return { commit: "Commit", fetch: "Fetch", push: "Push" }[operation]; }
function nullable(value: string): string | null { const normalized = value.trim(); return normalized || null; }
