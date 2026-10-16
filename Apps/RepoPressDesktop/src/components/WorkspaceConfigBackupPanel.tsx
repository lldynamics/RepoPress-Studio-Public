import { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n/i18n";
import type { UiMessage } from "../i18n/uiMessage";
import { workspaceBackupMessages } from "../i18n/workspaceBackupMessages";
import { renderBackupExportMessage } from "../features/workspace/backupExportPresentation";
import {
  WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES,
  WORKSPACE_CONFIG_BACKUP_SOURCES,
  type WorkspaceConfigBackupGateway,
  type WorkspaceConfigBackupPlan,
  type WorkspaceConfigBackupResult,
  type WorkspaceConfigBackupSource,
  type WorkspaceConfigBackupSummary,
} from "../contracts/workspaceConfigBackup";
import { WORKSPACE_BACKUP_EXCLUSIONS } from "../contracts/workspaceBackup";

export interface WorkspaceConfigBackupPanelProps {
  gateway: WorkspaceConfigBackupGateway;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
}

const TTL_MS = 300000;
const MAX_TIME = 8.64e15;
const MAX_TOTAL = 8 * 1024 * 1024;
const sourceLabels: Record<WorkspaceConfigBackupSource, string> = { workspace: "工作区配置", siteProfiles: "站点配置", aiProfiles: "AI 配置" };
const exclusionLabels: Record<(typeof WORKSPACE_BACKUP_EXCLUSIONS)[number], string> = {
  credentials: "凭据独立排除（不读取）", encryptedChat: "加密聊天内容", releaseLedgers: "发布台账（独立处理）", operationLogs: "操作日志",
  repositoryFiles: "仓库文件", externalAttachments: "外部附件", runtimeState: "运行时状态", unknownLocations: "未知位置",
};
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const sha = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const absPath = (value: unknown): value is string => typeof value === "string" && value.length > 0 && (value.startsWith("/") || /^[A-Za-z]:[\\/]/.test(value));
const validTime = (value: unknown): value is number => safeInt(value) && value > 0 && value <= MAX_TIME;
const sameSources = (a: readonly WorkspaceConfigBackupSource[], b: readonly WorkspaceConfigBackupSource[]) => a.length === b.length && a.every((item, index) => item === b[index]);
const sortedSources = (values: unknown): values is WorkspaceConfigBackupSource[] => Array.isArray(values) && values.length >= 1 && new Set(values).size === values.length
  && values.every((item) => WORKSPACE_CONFIG_BACKUP_SOURCES.includes(item as WorkspaceConfigBackupSource))
  && values.every((item, index, all) => index === 0 || WORKSPACE_CONFIG_BACKUP_SOURCES.indexOf(item as WorkspaceConfigBackupSource) > WORKSPACE_CONFIG_BACKUP_SOURCES.indexOf(all[index - 1] as WorkspaceConfigBackupSource));

function validSummary(value: unknown): value is WorkspaceConfigBackupSummary {
  if (!value || typeof value !== "object") return false;
  const item = value as WorkspaceConfigBackupSummary;
  if (!WORKSPACE_CONFIG_BACKUP_SOURCES.includes(item.source) || !safeInt(item.sourceByteSize) || item.sourceByteSize <= 0
    || !safeInt(item.itemCount) || item.itemCount < 0 || !safeInt(item.recoveryDraftCount) || ![0, 1].includes(item.recoveryDraftCount)) return false;
  if (item.source === "workspace") return item.itemCount === 1 && item.sourceByteSize <= 5 * 1024 * 1024;
  if (item.source === "siteProfiles") return item.itemCount <= 32 && item.recoveryDraftCount === 0 && item.sourceByteSize <= 256 * 1024;
  return item.itemCount <= 16 && item.recoveryDraftCount === 0 && item.sourceByteSize <= 128 * 1024;
}

function validPlan(value: unknown, sources: readonly WorkspaceConfigBackupSource[], destinationPath: string): value is WorkspaceConfigBackupPlan {
  if (!value || typeof value !== "object") return false;
  const plan = value as WorkspaceConfigBackupPlan;
  if (!uuid(plan.planId) || plan.scope !== "applicationPrivateConfiguration" || plan.format !== "repopress-workspace-config" || plan.schemaVersion !== 1
    || plan.destinationPath !== destinationPath || !absPath(plan.destinationPath) || !sortedSources(plan.selectedSources) || !sameSources(plan.selectedSources, sources)
    || !Array.isArray(plan.sources) || plan.sources.length !== sources.length || plan.sources.some((item, index) => !validSummary(item) || item.source !== sources[index])
    || !Array.isArray(plan.excludedSources) || plan.excludedSources.length !== WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES.length
    || new Set(plan.excludedSources).size !== WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES.length || !WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES.every((item) => plan.excludedSources.includes(item))
    || !Array.isArray(plan.exclusions) || plan.exclusions.length !== WORKSPACE_BACKUP_EXCLUSIONS.length || new Set(plan.exclusions).size !== WORKSPACE_BACKUP_EXCLUSIONS.length
    || !WORKSPACE_BACKUP_EXCLUSIONS.every((item) => plan.exclusions.includes(item)) || plan.structureVerified !== true || plan.consistentSnapshot !== false || plan.includesCredentials !== false
    || !safeInt(plan.byteSize) || plan.byteSize <= 0 || plan.byteSize > MAX_TOTAL || !sha(plan.sha256) || !validTime(plan.createdAtEpochMs) || !validTime(plan.expiresAtEpochMs)
    || plan.createdAtEpochMs > Date.now() || plan.expiresAtEpochMs <= Date.now() || plan.expiresAtEpochMs - plan.createdAtEpochMs !== TTL_MS) return false;
  return plan.sources.reduce((sum, item) => sum + item.sourceByteSize, 0) <= 5 * 1024 * 1024 + 384 * 1024;
}

function validResult(value: unknown, plan: WorkspaceConfigBackupPlan): value is WorkspaceConfigBackupResult {
  if (!value || typeof value !== "object") return false;
  const result = value as WorkspaceConfigBackupResult;
  return result.planId === plan.planId && result.destinationPath === plan.destinationPath && Array.isArray(result.selectedSources) && sameSources(result.selectedSources, plan.selectedSources)
    && result.byteSize === plan.byteSize && result.sha256 === plan.sha256;
}

export function WorkspaceConfigBackupPanel({ gateway, enabled, disabled = false, refreshKey }: WorkspaceConfigBackupPanelProps) {
  const { locale, t } = useI18n(workspaceBackupMessages);
  const number = (value: number) => value.toLocaleString(locale);
  const date = (value: number) => new Date(value).toLocaleString(locale);
  const list = (values: string[]) => values.join(locale === "en-US" ? ", " : "、");
  const [selected, setSelected] = useState<WorkspaceConfigBackupSource[]>(["workspace"]);
  const [destinationPath, setDestinationPath] = useState<string | null>(null);
  const [plan, setPlan] = useState<WorkspaceConfigBackupPlan | null>(null);
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState<"selecting" | "planning" | "exporting" | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState<UiMessage | null>(null);
  const generation = useRef(0); const busyRef = useRef(false); const planRef = useRef<WorkspaceConfigBackupPlan | null>(null);
  const consentRef = useRef(false);
  const contextRef = useRef({ gateway, enabled, disabled, refreshKey, selected, destinationPath });
  contextRef.current = { gateway, enabled, disabled, refreshKey, selected, destinationPath };
  consentRef.current = consent;
  const planContextRef = useRef<typeof contextRef.current | null>(null);
  const usable = enabled && !disabled;
  const sameContext = (candidate: typeof contextRef.current) => contextRef.current.gateway === candidate.gateway && contextRef.current.enabled === candidate.enabled
    && contextRef.current.disabled === candidate.disabled && contextRef.current.refreshKey === candidate.refreshKey && sameSources(contextRef.current.selected, candidate.selected)
    && contextRef.current.destinationPath === candidate.destinationPath;
  const discard = (candidate: WorkspaceConfigBackupPlan | null, boundGateway = gateway) => { if (candidate) void boundGateway.discardWorkspaceConfigBackup(candidate.planId).catch(() => undefined); };
  const current = usable && planRef.current === plan && planContextRef.current !== null && sameContext(planContextRef.current) && validPlan(plan, selected, destinationPath ?? "") ? plan : null;

  useEffect(() => {
    const old = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(old, oldGateway); generation.current += 1; busyRef.current = false;
    setPlan(null); consentRef.current = false; setConsent(false); setBusy(null); setError(""); setMessage(null);
    return () => { const currentPlan = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(currentPlan, oldGateway); generation.current += 1; busyRef.current = false; };
  }, [gateway, enabled, disabled, refreshKey]);
  useEffect(() => {
    if (!current) return;
    const timer = window.setTimeout(() => { if (planRef.current !== current) return; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(current, oldGateway); setPlan(null); consentRef.current = false; setConsent(false); setError("计划已过期，请重新生成。"); }, Math.max(0, current.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [current?.planId, current?.expiresAtEpochMs]);

  function invalidate() { const old = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(old, oldGateway); generation.current += 1; setPlan(null); consentRef.current = false; setConsent(false); setError(""); setMessage(null); }
  function changeSource(source: WorkspaceConfigBackupSource, checked: boolean) { if (busyRef.current) return; invalidate(); setSelected(WORKSPACE_CONFIG_BACKUP_SOURCES.filter((item) => item === source ? checked : selected.includes(item))); }

  async function chooseDestination() {
    if (!usable || busyRef.current) return;
    invalidate(); setDestinationPath(null); const request = ++generation.current; const requestContext = { ...contextRef.current, destinationPath: null }; busyRef.current = true; setBusy("selecting");
    try { const value = await gateway.selectWorkspaceConfigBackupDestination(); if (request !== generation.current || !sameContext(requestContext) || !usable) return; if (value !== null && !absPath(value)) throw new Error("invalid"); if (value !== null) setDestinationPath(value); }
    catch { if (request === generation.current && sameContext(requestContext)) setError("无法选择新的归档文件路径，请选择新的绝对 JSON 文件路径。"); }
    finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } }
  }

  async function prepare() {
    const path = destinationPath; if (!usable || busyRef.current || !path || !absPath(path) || selected.length === 0) return;
    invalidate(); const request = ++generation.current; const requestContext = contextRef.current; busyRef.current = true; setBusy("planning");
    try { const next: unknown = await gateway.planWorkspaceConfigBackup([...selected], path); if (request !== generation.current || !sameContext(requestContext) || !usable || destinationPath !== path) { if (next && typeof next === "object" && uuid((next as Partial<WorkspaceConfigBackupPlan>).planId)) discard(next as WorkspaceConfigBackupPlan, requestContext.gateway); return; }
      if (!validPlan(next, selected, path)) {
        const invalid = next && typeof next === "object" ? next as Partial<WorkspaceConfigBackupPlan> : null;
        if (invalid && uuid(invalid.planId)) discard(invalid as WorkspaceConfigBackupPlan, requestContext.gateway);
        throw new Error("invalid");
      }
      planRef.current = next; planContextRef.current = requestContext; setPlan(next);
    } catch { if (request === generation.current && sameContext(requestContext)) setError("无法生成配置备份预览；请确认目的地是新的绝对 JSON 文件路径。"); }
    finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } }
  }

  async function execute() {
    const captured = current; const capturedContext = planContextRef.current;
    if (!usable || disabled || busyRef.current || !captured || !capturedContext || planRef.current !== captured || !sameContext(capturedContext) || !consentRef.current || captured.expiresAtEpochMs <= Date.now()) return;
    planRef.current = null; planContextRef.current = null; setPlan(null); consentRef.current = false; setConsent(false); busyRef.current = true; setBusy("exporting"); setError(""); setMessage(null); const request = ++generation.current; const requestContext = capturedContext;
    try { const result: unknown = await gateway.executeWorkspaceConfigBackup(captured.planId, true); if (request !== generation.current || !sameContext(requestContext) || !validResult(result, captured)) throw new Error("invalid"); setMessage({ source: "已导出并核验本地 JSON 文件：{path}；SHA-256：{sha}。", parameters: { path: captured.destinationPath, sha: captured.sha256 } }); }
    catch { if (request === generation.current && sameContext(requestContext)) setError("配置备份导出结果未明；计划已消耗，不会自动重试。文件可能已存在，请查验后选择新路径。"); }
    finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } }
  }

  return <section className="operation-plan" aria-label={t("配置备份导出")} aria-busy={busy !== null}>
    <h4>{t("配置备份导出")}</h4>
    <p className="publish-muted">{t("仅导出 3 类已保存 JSON 配置：工作区、站点配置和 AI 配置。打开预览会在本机读取所选 JSON；结构校验不证明跨来源原子快照或完整工作区恢复。知识库、RSS、普通草稿、草稿历史等正文范围固定排除；凭据独立排除，不会自动脱敏配置中自带的秘密。")}</p>
    <div>{WORKSPACE_CONFIG_BACKUP_SOURCES.map((source) => <label key={source} style={{ display: "block" }}><input type="checkbox" checked={selected.includes(source)} onChange={(event) => changeSource(source, event.target.checked)} disabled={!usable || busy !== null} />{t(sourceLabels[source])}</label>)}</div>
    <p className="publish-muted">{t("固定排除正文范围：{sources}。固定排除敏感范围：{exclusions}。", { sources: list(WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES.map((source) => t(source === "knowledge" ? "知识库正文" : source === "rss" ? "RSS 正文" : source === "generalDrafts" ? "普通草稿正文" : "草稿历史正文"))), exclusions: list(WORKSPACE_BACKUP_EXCLUSIONS.map((source) => t(exclusionLabels[source]))) })}</p>
    <button type="button" onClick={() => void chooseDestination()} disabled={!usable || busy !== null}>{t("选择新的 JSON 文件路径")}</button>
    {destinationPath && <p>{t("目标路径：{path}", { path: destinationPath })}</p>}
    {destinationPath && <button type="button" onClick={() => void prepare()} disabled={!usable || busy !== null || selected.length === 0}>{t("明确预览配置备份")}</button>}
    {busy === "selecting" && <p role="status" className="publish-muted">{t("正在选择路径…")}</p>}{busy === "planning" && <p role="status" className="publish-muted">{t("正在生成配置备份预览…")}</p>}{busy === "exporting" && <p role="status" className="publish-muted">{t("正在导出并核验 JSON 文件…")}</p>}
    {error && <p role="alert" className="publish-warning">{t(error)}</p>}{message && <p role="status">{renderBackupExportMessage(message, locale, t)}</p>}
    {current && <div className="operation-plan">
      <p><strong>{t("配置备份预览（一次性，5 分钟内有效）")}</strong></p>
      <p>{t("范围：{sources}", { sources: list(current.selectedSources.map((source) => t(sourceLabels[source]))) })}</p>
      {current.sources.map((item) => <p key={item.source}>{t(item.recoveryDraftCount ? "{source}：{count} 项，{bytes} 字节，含恢复草稿" : "{source}：{count} 项，{bytes} 字节", { source: t(sourceLabels[item.source]), count: number(item.itemCount), bytes: number(item.sourceByteSize) })}</p>)}
      <p>{t("总大小：{bytes} 字节；SHA-256：{sha}", { bytes: number(current.byteSize), sha: current.sha256 })}</p>
      <p>{t("有效至：{date}", { date: date(current.expiresAtEpochMs) })}</p>
      <p className="publish-warning">{t("明文配置可能包含恢复稿正文和路径、AI 端点；内容与 URL 可能自带秘密，系统不会自动脱敏。凭据独立排除。")}</p>
      <label htmlFor="workspace-config-backup-consent"><input id="workspace-config-backup-consent" type="checkbox" checked={consent} onChange={(event) => { consentRef.current = event.target.checked; setConsent(event.target.checked); }} disabled={busy !== null || !usable} />{t("我已知悉并同意导出可能包含敏感明文配置")}</label>
      <button type="button" onClick={() => void execute()} disabled={!usable || disabled || busy !== null || !consent}>{t("明确一次性导出配置备份")}</button>
      <button type="button" onClick={invalidate} disabled={busy !== null}>{t("取消配置备份计划")}</button>
    </div>}
  </section>;
}
