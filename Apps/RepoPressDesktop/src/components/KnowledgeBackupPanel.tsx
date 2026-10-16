import { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n/i18n";
import type { UiMessage } from "../i18n/uiMessage";
import { workspaceBackupMessages } from "../i18n/workspaceBackupMessages";
import { renderBackupExportMessage } from "../features/workspace/backupExportPresentation";
import { KNOWLEDGE_BACKUP_EXCLUSIONS, KNOWLEDGE_BACKUP_LIMITS, type KnowledgeBackupGateway, type KnowledgeBackupPlan, type KnowledgeBackupResult } from "../contracts/knowledgeBackup";

export interface KnowledgeBackupPanelProps { gateway: KnowledgeBackupGateway; enabled: boolean; disabled?: boolean; refreshKey?: number; }

const TTL = 300000;
const MAX_TIME = 8.64e15;
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const sha = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
const time = (value: unknown): value is number => safeInt(value) && value > 0 && value <= MAX_TIME;
const absJson = (value: unknown): value is string => {
  if (typeof value !== "string" || !value.startsWith("/") || !value.endsWith(".json") || value.includes("\0")) return false;
  return value.split("/").every((part) => part !== ".." && part !== ".");
};
const exactArray = (value: unknown): value is typeof KNOWLEDGE_BACKUP_EXCLUSIONS[number][] => Array.isArray(value) && value.length === KNOWLEDGE_BACKUP_EXCLUSIONS.length && new Set(value).size === KNOWLEDGE_BACKUP_EXCLUSIONS.length && KNOWLEDGE_BACKUP_EXCLUSIONS.every((item) => value.includes(item));
const exactLimits = (value: unknown): value is typeof KNOWLEDGE_BACKUP_LIMITS => {
  if (!value || typeof value !== "object") return false;
  const limits = value as Record<string, unknown>;
  const keys = ["manifestBytes", "resourceFiles", "resourceBytes", "packageBytes", "durationMs"];
  return Object.keys(limits).length === keys.length && keys.every((key) => limits[key] === KNOWLEDGE_BACKUP_LIMITS[key as keyof typeof KNOWLEDGE_BACKUP_LIMITS]);
};
const exclusionLabels: Record<typeof KNOWLEDGE_BACKUP_EXCLUSIONS[number], string> = {
  credentialStores: "凭据存储",
  otherWorkspaceSources: "其他工作区来源",
  repositoryFiles: "仓库当前文件",
  externalReferences: "外部引用内容",
  unreferencedFiles: "未引用文件",
  sourcePdfFiles: "PDF 原文件",
  attachmentFiles: "附件原文件",
  completedOperations: "持久操作回执",
  runtimeState: "运行时状态",
};

function validPlan(value: unknown, destinationPath: string): value is KnowledgeBackupPlan {
  if (!value || typeof value !== "object") return false;
  const plan = value as KnowledgeBackupPlan;
  return uuid(plan.planId) && plan.scope === "applicationSavedKnowledge" && plan.format === "repopress-knowledge-saved-files" && plan.schemaVersion === 1 && plan.sourceManifestSchemaVersion === 4
    && plan.destinationPath === destinationPath && absJson(destinationPath)
    && safeInt(plan.itemCount) && plan.itemCount <= 2000 && safeInt(plan.revisionCount) && plan.revisionCount <= plan.itemCount * 32 && (plan.itemCount === 0 ? plan.revisionCount === 0 : plan.revisionCount >= plan.itemCount)
    && safeInt(plan.bodyFileCount) && safeInt(plan.archiveFileCount) && plan.bodyFileCount <= plan.revisionCount && plan.archiveFileCount <= plan.revisionCount && plan.bodyFileCount + plan.archiveFileCount <= KNOWLEDGE_BACKUP_LIMITS.resourceFiles && (plan.itemCount === 0 ? plan.bodyFileCount === 0 : plan.bodyFileCount >= 1)
    && safeInt(plan.resourceByteSize) && plan.resourceByteSize <= KNOWLEDGE_BACKUP_LIMITS.resourceBytes && (plan.bodyFileCount + plan.archiveFileCount > 0 || plan.resourceByteSize === 0)
    && safeInt(plan.byteSize) && plan.byteSize > 0 && plan.byteSize >= plan.resourceByteSize && plan.byteSize <= KNOWLEDGE_BACKUP_LIMITS.packageBytes && sha(plan.sha256)
    && exactArray(plan.exclusions) && exactLimits(plan.limits)
    && plan.structureVerified === true && plan.contentVerified === true && plan.allSavedReferencesIncluded === true && plan.consistentSnapshot === false
    && plan.includesCredentialStores === false && plan.includesCompletedOperations === false && plan.externalReferencesIncluded === false
    && time(plan.createdAtEpochMs) && time(plan.expiresAtEpochMs) && plan.createdAtEpochMs <= Date.now() && plan.expiresAtEpochMs > Date.now() && plan.expiresAtEpochMs - plan.createdAtEpochMs === TTL;
}

function validResult(value: unknown, plan: KnowledgeBackupPlan): value is KnowledgeBackupResult {
  if (!value || typeof value !== "object") return false;
  const result = value as KnowledgeBackupResult;
  return uuid(result.planId) && result.planId === plan.planId && result.destinationPath === plan.destinationPath && safeInt(result.byteSize) && result.byteSize === plan.byteSize && sha(result.sha256) && result.sha256 === plan.sha256;
}

export function KnowledgeBackupPanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeBackupPanelProps) {
  const { locale, t } = useI18n(workspaceBackupMessages);
  const number = (value: number) => value.toLocaleString(locale);
  const date = (value: number) => new Date(value).toLocaleString(locale);
  const list = (values: string[]) => values.join(locale === "en-US" ? ", " : "、");
  const [destinationPath, setDestinationPath] = useState<string | null>(null);
  const [plan, setPlan] = useState<KnowledgeBackupPlan | null>(null);
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState<"selecting" | "planning" | "exporting" | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState<UiMessage | null>(null);
  const generation = useRef(0); const busyRef = useRef(false); const planRef = useRef<KnowledgeBackupPlan | null>(null); const consentRef = useRef(false);
  const contextRef = useRef({ gateway, enabled, disabled, refreshKey, destinationPath }); contextRef.current = { gateway, enabled, disabled, refreshKey, destinationPath }; consentRef.current = consent;
  const planContextRef = useRef<typeof contextRef.current | null>(null);
  const usable = enabled && !disabled;
  const sameContext = (candidate: typeof contextRef.current) => contextRef.current.gateway === candidate.gateway && contextRef.current.enabled === candidate.enabled && contextRef.current.disabled === candidate.disabled && contextRef.current.refreshKey === candidate.refreshKey && contextRef.current.destinationPath === candidate.destinationPath;
  const discard = (item: KnowledgeBackupPlan | null, boundGateway = gateway) => { if (item) void boundGateway.discardKnowledgeBackup(item.planId).catch(() => undefined); };
  const current = usable && planRef.current === plan && planContextRef.current !== null && sameContext(planContextRef.current) && validPlan(plan, destinationPath ?? "") ? plan : null;

  useEffect(() => { const old = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(old, oldGateway); generation.current += 1; busyRef.current = false; setPlan(null); setDestinationPath(null); consentRef.current = false; setConsent(false); setBusy(null); setError(""); setMessage(null); return () => { const oldPlan = planRef.current; const gatewayForOld = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(oldPlan, gatewayForOld); generation.current += 1; busyRef.current = false; }; }, [gateway, enabled, disabled, refreshKey]);
  useEffect(() => { if (!current) return; const timer = window.setTimeout(() => { if (planRef.current !== current) return; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(current, oldGateway); setPlan(null); consentRef.current = false; setConsent(false); setError("计划已过期，请重新生成。"); }, Math.max(0, current.expiresAtEpochMs - Date.now())); return () => window.clearTimeout(timer); }, [current?.planId, current?.expiresAtEpochMs]);

  function invalidate() { const old = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(old, oldGateway); generation.current += 1; setPlan(null); consentRef.current = false; setConsent(false); setError(""); setMessage(null); }
  async function choose() { if (!usable || busyRef.current) return; invalidate(); contextRef.current = { ...contextRef.current, destinationPath: null }; setDestinationPath(null); const request = ++generation.current; const requestContext = { ...contextRef.current, destinationPath: null }; busyRef.current = true; setBusy("selecting"); try { const next = await gateway.selectKnowledgeBackupDestination(); if (request !== generation.current || !sameContext(requestContext) || !usable) return; if (next !== null && !absJson(next)) throw new Error("invalid"); if (next !== null) setDestinationPath(next); } catch { if (request === generation.current && sameContext(requestContext)) setError("无法选择新的资料 JSON 文件路径，请选择新的绝对小写 .json 文件路径。"); } finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } } }
  async function prepare() { const path = destinationPath; if (!usable || busyRef.current || !path || !absJson(path)) return; invalidate(); const request = ++generation.current; const requestContext = contextRef.current; busyRef.current = true; setBusy("planning"); try { const next: unknown = await gateway.planKnowledgeBackup(path); if (request !== generation.current || !sameContext(requestContext) || !usable || destinationPath !== path) { if (next && typeof next === "object" && uuid((next as Partial<KnowledgeBackupPlan>).planId)) discard(next as KnowledgeBackupPlan, requestContext.gateway); return; } if (!validPlan(next, path)) { const invalid = next && typeof next === "object" ? next as Partial<KnowledgeBackupPlan> : null; if (invalid && uuid(invalid.planId)) discard(invalid as KnowledgeBackupPlan, requestContext.gateway); throw new Error("invalid"); } planRef.current = next; planContextRef.current = requestContext; setPlan(next); } catch { if (request === generation.current && sameContext(requestContext)) setError("无法生成资料备份包预览；资料清单或资源超出限制、状态不完整或路径无效。"); } finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } } }
  async function execute() { const captured = current; const capturedContext = planContextRef.current; if (!usable || disabled || busyRef.current || !captured || !capturedContext || planRef.current !== captured || !sameContext(capturedContext) || !consentRef.current || captured.expiresAtEpochMs <= Date.now()) return; planRef.current = null; planContextRef.current = null; consentRef.current = false; setPlan(null); setConsent(false); busyRef.current = true; setBusy("exporting"); setError(""); setMessage(null); const request = ++generation.current; try { const result: unknown = await gateway.executeKnowledgeBackup(captured.planId, true); if (request !== generation.current || !sameContext(capturedContext) || !validResult(result, captured)) throw new Error("invalid"); setMessage({ source: "已导出并核验本地资料 JSON 文件：{path}；大小：{bytes} 字节；SHA-256：{sha}。", parameters: { path: captured.destinationPath, bytes: captured.byteSize, sha: captured.sha256 } }); } catch { if (request === generation.current && sameContext(capturedContext)) setError("资料备份包导出结果未明；计划已消耗，不会自动重试。请查验文件后选择新的路径。已有文件不会被自动覆盖。"); } finally { if (request === generation.current && sameContext(capturedContext)) { busyRef.current = false; setBusy(null); } } }
  function changeConsent(next: boolean) { const candidate = planRef.current; const boundContext = planContextRef.current; const valid = usable && !busyRef.current && busy === null && candidate !== null && candidate === plan && boundContext !== null && sameContext(boundContext) && validPlan(candidate, destinationPath ?? "") && candidate.expiresAtEpochMs > Date.now(); consentRef.current = valid && next; setConsent(valid && next); }

  return <section className="operation-plan" aria-label={t("资料保存文件备份包")} aria-busy={busy !== null}>
    <h4>{t("资料保存文件备份包")}</h4>
    <p className="publish-muted">{t("导出全部已保存资料，以及全部历史正文和存档；预览只显示数量、大小、SHA-256、目标路径与有效期，不显示标题、来源 URL、正文或其他元数据。资料项会保留文件夹、标题、来源 URL 与已保存偏好；包内是可逆的 base64 明文，不是加密。")}</p>
    <p className="publish-warning">{t("固定排除凭据、运行时状态、未引用文件和外部引用内容；外部引用内容不会抓取，来源 URL 元数据和保存正文内的 URL 字符串仍保留。PDF 原文件与附件原文件也固定排除，但 PDF 提取后已保存的正文及元数据仍包含在包内。固定排除还包括持久操作回执和其他来源；存档不完整或完整性未知时计划会失败。这不是原子快照、全工作区备份、恢复机制或 macOS 交换格式。资料清单、资源数量、资源大小、JSON 包大小或 5 秒检查上限不足时，计划会失败。")}</p>
    <button type="button" onClick={() => void choose()} disabled={!usable || busy !== null}>{t("选择新的资料 JSON 文件路径")}</button>
    {destinationPath && <p>{t("目标路径：{path}", { path: destinationPath })}</p>}
    {destinationPath && <button type="button" onClick={() => void prepare()} disabled={!usable || busy !== null}>{t("明确预览资料备份包")}</button>}
    {busy === "selecting" && <p role="status">{t("正在选择路径…")}</p>}{busy === "planning" && <p role="status">{t("正在生成资料备份包预览…")}</p>}{busy === "exporting" && <p role="status">{t("正在导出并核验 JSON 备份包…")}</p>}
    {error && <p role="alert" className="publish-warning">{t(error)}</p>}{message && <p role="status">{renderBackupExportMessage(message, locale, t)}</p>}
    {current && <div className="operation-plan">
      <p><strong>{t("资料备份包预览（一次性，5 分钟内有效）")}</strong></p>
      <p>{t("资料项：{items}；历史修订：{revisions}；正文文件：{bodies}；存档文件：{archives}", { items: number(current.itemCount), revisions: number(current.revisionCount), bodies: number(current.bodyFileCount), archives: number(current.archiveFileCount) })}</p>
      <p>{t("资源大小：{resources} 字节；JSON 包：{bytes} 字节；SHA-256：{sha}", { resources: number(current.resourceByteSize), bytes: number(current.byteSize), sha: current.sha256 })}</p>
      <p>{t("有效至：{date}", { date: date(current.expiresAtEpochMs) })}</p>
      <p>{t("固定排除：{exclusions}", { exclusions: list(current.exclusions.map((item) => t(exclusionLabels[item]))) })}</p>
      <label htmlFor="knowledge-backup-consent"><input id="knowledge-backup-consent" type="checkbox" checked={consent} onChange={(event) => changeConsent(event.target.checked)} disabled={busy !== null || !usable} />{t("我已知悉并同意导出敏感资料明文")}</label>
      <button type="button" onClick={() => void execute()} disabled={!usable || disabled || busy !== null || !consent}>{t("明确一次性导出资料备份包")}</button>
      <button type="button" onClick={invalidate} disabled={busy !== null}>{t("取消资料备份计划")}</button>
    </div>}
  </section>;
}
