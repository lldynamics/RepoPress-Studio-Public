import { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n/i18n";
import type { UiMessage } from "../i18n/uiMessage";
import { workspaceBackupMessages } from "../i18n/workspaceBackupMessages";
import { renderBackupExportMessage } from "../features/workspace/backupExportPresentation";
import { DRAFT_SNAPSHOT_EXCLUSIONS, DRAFT_SNAPSHOT_MAX_BYTES, DRAFT_SNAPSHOT_TABLES, type DraftSnapshotBackupGateway, type DraftSnapshotBackupPlan, type DraftSnapshotBackupResult, type DraftSnapshotSource } from "../contracts/draftSnapshotBackup";

export interface DraftSnapshotBackupPanelProps { gateway: DraftSnapshotBackupGateway; enabled: boolean; disabled?: boolean; refreshKey?: number; }
const TTL = 300000; const MAX_TIME = 8.64e15;
const sourceLabels: Record<DraftSnapshotSource, string> = { generalDrafts: "普通草稿数据库", draftHistory: "草稿历史数据库" };
const exclusionLabels: Record<typeof DRAFT_SNAPSHOT_EXCLUSIONS[number], string> = { credentialStores: "凭据存储", otherWorkspaceSources: "其他工作区来源", repositoryFiles: "仓库当前文件", externalAttachments: "外部附件", runtimeTransferState: "内存转移计划与撤销状态" };
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const sha = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const time = (value: unknown): value is number => safeInt(value) && value > 0 && value <= MAX_TIME;
const absSqlite = (value: unknown): value is string => typeof value === "string" && value.length > 7 && (value.startsWith("/") || /^[A-Za-z]:[\\/]/.test(value)) && value.toLowerCase().endsWith(".sqlite");

function validPlan(value: unknown, source: DraftSnapshotSource, destinationPath: string): value is DraftSnapshotBackupPlan {
  if (!value || typeof value !== "object") return false;
  const plan = value as DraftSnapshotBackupPlan; const tables = DRAFT_SNAPSHOT_TABLES[source];
  return uuid(plan.planId) && plan.scope === "applicationDraftDatabase" && plan.format === "sqlite3" && plan.schemaVersion === 1 && plan.source === source
    && plan.sourceSchema === "unversionedInstalledLayout" && plan.destinationPath === destinationPath && absSqlite(destinationPath)
    && Array.isArray(plan.tables) && plan.tables.length === tables.length && plan.tables.every((item, index) => item && item.table === tables[index] && safeInt(item.rowCount) && item.rowCount >= 0)
    && Array.isArray(plan.exclusions) && plan.exclusions.length === DRAFT_SNAPSHOT_EXCLUSIONS.length && new Set(plan.exclusions).size === DRAFT_SNAPSHOT_EXCLUSIONS.length && DRAFT_SNAPSHOT_EXCLUSIONS.every((item) => plan.exclusions.includes(item))
    && plan.structureVerified === true && plan.contentVerified === true && plan.consistentSnapshot === true && plan.multiDatabaseSnapshot === false && plan.includesCredentialStores === false
    && plan.includesRecycledDrafts === (source === "draftHistory") && plan.compactedCopy === true && safeInt(plan.byteSize) && plan.byteSize > 0 && plan.byteSize <= DRAFT_SNAPSHOT_MAX_BYTES && sha(plan.sha256)
    && time(plan.createdAtEpochMs) && time(plan.expiresAtEpochMs) && plan.createdAtEpochMs <= Date.now() && plan.expiresAtEpochMs > Date.now() && plan.expiresAtEpochMs - plan.createdAtEpochMs === TTL;
}
function validResult(value: unknown, plan: DraftSnapshotBackupPlan): value is DraftSnapshotBackupResult { if (!value || typeof value !== "object") return false; const result = value as DraftSnapshotBackupResult; return result.planId === plan.planId && result.source === plan.source && result.destinationPath === plan.destinationPath && result.byteSize === plan.byteSize && result.sha256 === plan.sha256; }

export function DraftSnapshotBackupPanel({ gateway, enabled, disabled = false, refreshKey }: DraftSnapshotBackupPanelProps) {
  const { locale, t } = useI18n(workspaceBackupMessages);
  const number = (value: number) => value.toLocaleString(locale);
  const date = (value: number) => new Date(value).toLocaleString(locale);
  const list = (values: string[]) => values.join(locale === "en-US" ? ", " : "、");
  const [source, setSource] = useState<DraftSnapshotSource>("generalDrafts"); const [destinationPath, setDestinationPath] = useState<string | null>(null); const [plan, setPlan] = useState<DraftSnapshotBackupPlan | null>(null); const [consent, setConsent] = useState(false); const [busy, setBusy] = useState<"selecting" | "planning" | "exporting" | null>(null); const [error, setError] = useState(""); const [message, setMessage] = useState<UiMessage | null>(null);
  const generation = useRef(0); const busyRef = useRef(false); const planRef = useRef<DraftSnapshotBackupPlan | null>(null); const consentRef = useRef(false); const contextRef = useRef({ gateway, enabled, disabled, refreshKey, source, destinationPath }); contextRef.current = { gateway, enabled, disabled, refreshKey, source, destinationPath }; consentRef.current = consent;
  const planContextRef = useRef<typeof contextRef.current | null>(null); const usable = enabled && !disabled; const sameContext = (candidate: typeof contextRef.current) => contextRef.current.gateway === candidate.gateway && contextRef.current.enabled === candidate.enabled && contextRef.current.disabled === candidate.disabled && contextRef.current.refreshKey === candidate.refreshKey && contextRef.current.source === candidate.source && contextRef.current.destinationPath === candidate.destinationPath; const discard = (item: DraftSnapshotBackupPlan | null, boundGateway = gateway) => { if (item) void boundGateway.discardDraftSnapshotBackup(item.planId).catch(() => undefined); }; const current = usable && planRef.current === plan && planContextRef.current !== null && sameContext(planContextRef.current) && validPlan(plan, source, destinationPath ?? "") ? plan : null;
  useEffect(() => { const old = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(old, oldGateway); generation.current += 1; busyRef.current = false; setPlan(null); consentRef.current = false; setConsent(false); setBusy(null); setError(""); setMessage(null); return () => { const oldPlan = planRef.current; const gatewayForOld = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(oldPlan, gatewayForOld); generation.current += 1; busyRef.current = false; }; }, [gateway, enabled, disabled, refreshKey]);
  useEffect(() => { if (!current) return; const timer = window.setTimeout(() => { if (planRef.current !== current) return; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(current, oldGateway); setPlan(null); consentRef.current = false; setConsent(false); setError("计划已过期，请重新生成。"); }, Math.max(0, current.expiresAtEpochMs - Date.now())); return () => window.clearTimeout(timer); }, [current?.planId, current?.expiresAtEpochMs]);
  function invalidate() { const old = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(old, oldGateway); generation.current += 1; setPlan(null); consentRef.current = false; setConsent(false); setError(""); setMessage(null); }
  function changeSource(next: DraftSnapshotSource) { if (busyRef.current || next === source) return; invalidate(); setSource(next); setDestinationPath(null); }
  async function choose() { if (!usable || busyRef.current) return; invalidate(); setDestinationPath(null); const request = ++generation.current; const requestContext = { ...contextRef.current, destinationPath: null }; busyRef.current = true; setBusy("selecting"); try { const next = await gateway.selectDraftSnapshotBackupDestination(source); if (request !== generation.current || !sameContext(requestContext) || !usable) return; if (next !== null && !absSqlite(next)) throw new Error("invalid"); if (next !== null) setDestinationPath(next); } catch { if (request === generation.current && sameContext(requestContext)) setError("无法选择新的草稿 SQLite 文件路径，请选择新的绝对 .sqlite 文件路径。"); } finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } } }
  async function prepare() { const path = destinationPath; if (!usable || busyRef.current || !path || !absSqlite(path)) return; invalidate(); const request = ++generation.current; const requestContext = contextRef.current; busyRef.current = true; setBusy("planning"); try { const next: unknown = await gateway.planDraftSnapshotBackup(source, path); if (request !== generation.current || !sameContext(requestContext) || !usable || destinationPath !== path) { if (next && typeof next === "object" && uuid((next as Partial<DraftSnapshotBackupPlan>).planId)) discard(next as DraftSnapshotBackupPlan, requestContext.gateway); return; } if (!validPlan(next, source, path)) { const invalid = next && typeof next === "object" ? next as Partial<DraftSnapshotBackupPlan> : null; if (invalid && uuid(invalid.planId)) discard(invalid as DraftSnapshotBackupPlan, requestContext.gateway); throw new Error("invalid"); } planRef.current = next; planContextRef.current = requestContext; setPlan(next); } catch { if (request === generation.current && sameContext(requestContext)) setError("无法生成草稿快照预览，请确认目的地是新的绝对 .sqlite 文件路径。"); } finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } } }
  async function execute() { const captured = current; const capturedContext = planContextRef.current; if (!usable || disabled || busyRef.current || !captured || !capturedContext || planRef.current !== captured || !sameContext(capturedContext) || !consentRef.current || captured.expiresAtEpochMs <= Date.now()) return; planRef.current = null; planContextRef.current = null; consentRef.current = false; setPlan(null); setConsent(false); busyRef.current = true; setBusy("exporting"); setError(""); setMessage(null); const request = ++generation.current; try { const result: unknown = await gateway.executeDraftSnapshotBackup(captured.planId, true); if (request !== generation.current || !sameContext(capturedContext) || !validResult(result, captured)) throw new Error("invalid"); setMessage({ source: "已导出并核验本地草稿 SQLite 文件：{path}；SHA-256：{sha}。", parameters: { path: captured.destinationPath, sha: captured.sha256 } }); } catch { if (request === generation.current && sameContext(capturedContext)) setError("草稿快照导出结果未明；计划已消耗，不会自动重试。文件可能已存在，请查验后选择新路径。"); } finally { if (request === generation.current && sameContext(capturedContext)) { busyRef.current = false; setBusy(null); } } }
  return <section className="operation-plan" aria-label={t("草稿数据库快照")} aria-busy={busy !== null}>
    <h4>{t("草稿数据库快照")}</h4>
    <p className="publish-muted">{t("每次只选择一个草稿数据库。预览会在本机读取当前选择的整库，但只显示数量、大小和 SHA，不展示条目的标题、来源路径或正文；32 MiB 上限。普通草稿数据库包含全部已保存草稿，草稿历史数据库覆盖所有仓库和回收正文；来源切换后需重新预览。")}</p>
    <p className="publish-warning">{t("正文、标题、路径和 Markdown URL 可能含秘密，不会自动脱敏。附件、仓库当前文件、未选其他库、凭据、内存转移计划与撤销状态固定排除。单库一致快照不是全工作区备份、恢复或 macOS 版交换格式，也不会清理源库。")}</p>
    <div role="radiogroup" aria-label={t("草稿数据库")}>
      <label><input type="radio" name="draft-snapshot-source" checked={source === "generalDrafts"} onChange={() => changeSource("generalDrafts")} disabled={!usable || busy !== null} />{t("普通草稿数据库")}</label>
      <label><input type="radio" name="draft-snapshot-source" checked={source === "draftHistory"} onChange={() => changeSource("draftHistory")} disabled={!usable || busy !== null} />{t("草稿历史数据库")}</label>
    </div>
    <button type="button" onClick={() => void choose()} disabled={!usable || busy !== null}>{t("选择新的草稿 SQLite 文件路径")}</button>
    {destinationPath && <p>{t("目标路径：{path}", { path: destinationPath })}</p>}
    {destinationPath && <button type="button" onClick={() => void prepare()} disabled={!usable || busy !== null}>{t("明确预览草稿快照")}</button>}
    {busy === "selecting" && <p role="status">{t("正在选择路径…")}</p>}{busy === "planning" && <p role="status">{t("正在生成草稿快照预览…")}</p>}{busy === "exporting" && <p role="status">{t("正在导出并核验 SQLite 文件…")}</p>}
    {error && <p role="alert" className="publish-warning">{t(error)}</p>}{message && <p role="status">{renderBackupExportMessage(message, locale, t)}</p>}
    {current && <div className="operation-plan">
      <p><strong>{t("{source}预览（一次性，5 分钟内有效）", { source: t(sourceLabels[current.source]) })}</strong></p>
      {current.tables.map((item) => <p key={item.table}>{t("{table}：{count} 条", { table: t(item.table === "general_drafts" ? "草稿" : item.table === "drafts" ? "历史草稿" : item.table === "versions" ? "版本" : "回收草稿"), count: number(item.rowCount) })}</p>)}
      <p>{t("大小：{bytes} 字节；SHA-256：{sha}", { bytes: number(current.byteSize), sha: current.sha256 })}</p>
      <p>{t("有效至：{date}", { date: date(current.expiresAtEpochMs) })}</p>
      <p>{t("固定排除：{exclusions}", { exclusions: list(current.exclusions.map((item) => t(exclusionLabels[item]))) })}</p>
      <label htmlFor="draft-snapshot-backup-consent"><input id="draft-snapshot-backup-consent" type="checkbox" checked={consent} onChange={(event) => { consentRef.current = event.target.checked; setConsent(event.target.checked); }} disabled={busy !== null || !usable} />{t("我已知悉并同意导出敏感草稿明文")}</label>
      <button type="button" onClick={() => void execute()} disabled={!usable || disabled || busy !== null || !consent}>{t("明确一次性导出草稿快照")}</button>
      <button type="button" onClick={invalidate} disabled={busy !== null}>{t("取消草稿快照计划")}</button>
    </div>}
  </section>;
}
