import { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n/i18n";
import type { UiMessage } from "../i18n/uiMessage";
import { workspaceBackupMessages } from "../i18n/workspaceBackupMessages";
import { renderBackupExportMessage } from "../features/workspace/backupExportPresentation";
import { RSS_SNAPSHOT_EXCLUSIONS, RSS_SNAPSHOT_MAX_BYTES, RSS_SNAPSHOT_TABLES, type RssSnapshotBackupGateway, type RssSnapshotBackupPlan, type RssSnapshotBackupResult } from "../contracts/rssSnapshotBackup";

export interface RssSnapshotBackupPanelProps { gateway: RssSnapshotBackupGateway; enabled: boolean; disabled?: boolean; refreshKey?: number; }
const TTL = 300000; const MAX_TIME = 8.64e15;
const tableLabels: Record<typeof RSS_SNAPSHOT_TABLES[number], string> = { meta: "数据库元信息", feeds: "订阅源", articles: "文章", highlights: "笔记", reading_progress: "阅读进度", undo_actions: "临时撤销记录", full_text_cache: "全文缓存", offline_translation_cache: "离线翻译缓存", history_jobs: "历史补全检查点", history_failures: "历史补全失败记录" };
const exclusionLabels: Record<typeof RSS_SNAPSHOT_EXCLUSIONS[number], string> = { credentialStores: "凭据存储", otherWorkspaceSources: "其他工作区来源", externalAttachments: "外部附件" };
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const sha = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const time = (value: unknown): value is number => safeInt(value) && value > 0 && value <= MAX_TIME;
const absoluteSqlite = (value: unknown): value is string => typeof value === "string" && value.length > 7 && (value.startsWith("/") || /^[A-Za-z]:[\\/]/.test(value)) && value.toLowerCase().endsWith(".sqlite");

function validPlan(value: unknown, destinationPath: string): value is RssSnapshotBackupPlan {
  if (!value || typeof value !== "object") return false;
  const plan = value as RssSnapshotBackupPlan;
  if (!uuid(plan.planId) || plan.scope !== "applicationRssDatabase" || plan.format !== "sqlite3" || plan.schemaVersion !== 1 || plan.databaseSchemaVersion !== 4
    || plan.destinationPath !== destinationPath || !absoluteSqlite(plan.destinationPath) || !Array.isArray(plan.tables) || plan.tables.length !== RSS_SNAPSHOT_TABLES.length
    || plan.tables.some((item, index) => !item || item.table !== RSS_SNAPSHOT_TABLES[index] || !safeInt(item.rowCount) || item.rowCount < 0)
    || !Array.isArray(plan.exclusions) || plan.exclusions.length !== RSS_SNAPSHOT_EXCLUSIONS.length || new Set(plan.exclusions).size !== RSS_SNAPSHOT_EXCLUSIONS.length
    || !RSS_SNAPSHOT_EXCLUSIONS.every((item) => plan.exclusions.includes(item)) || plan.structureVerified !== true || plan.consistentSnapshot !== true
    || plan.includesCredentialStores !== false || plan.includesUndoActions !== true || plan.compactedCopy !== true || !safeInt(plan.byteSize) || plan.byteSize <= 0 || plan.byteSize > RSS_SNAPSHOT_MAX_BYTES
    || !sha(plan.sha256) || !time(plan.createdAtEpochMs) || !time(plan.expiresAtEpochMs) || plan.createdAtEpochMs > Date.now() || plan.expiresAtEpochMs <= Date.now()
    || plan.expiresAtEpochMs - plan.createdAtEpochMs !== TTL) return false;
  return true;
}
function validResult(value: unknown, plan: RssSnapshotBackupPlan): value is RssSnapshotBackupResult {
  if (!value || typeof value !== "object") return false;
  const result = value as RssSnapshotBackupResult;
  return result.planId === plan.planId && result.destinationPath === plan.destinationPath && result.byteSize === plan.byteSize && result.sha256 === plan.sha256;
}

export function RssSnapshotBackupPanel({ gateway, enabled, disabled = false, refreshKey }: RssSnapshotBackupPanelProps) {
  const { locale, t } = useI18n(workspaceBackupMessages);
  const number = (value: number) => value.toLocaleString(locale);
  const date = (value: number) => new Date(value).toLocaleString(locale);
  const list = (values: string[]) => values.join(locale === "en-US" ? ", " : "、");
  const [destinationPath, setDestinationPath] = useState<string | null>(null); const [plan, setPlan] = useState<RssSnapshotBackupPlan | null>(null); const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState<"selecting" | "planning" | "exporting" | null>(null); const [error, setError] = useState(""); const [message, setMessage] = useState<UiMessage | null>(null);
  const generation = useRef(0); const busyRef = useRef(false); const planRef = useRef<RssSnapshotBackupPlan | null>(null); const consentRef = useRef(false);
  const contextRef = useRef({ gateway, enabled, disabled, refreshKey, destinationPath }); contextRef.current = { gateway, enabled, disabled, refreshKey, destinationPath }; consentRef.current = consent;
  const planContextRef = useRef<typeof contextRef.current | null>(null); const usable = enabled && !disabled;
  const sameContext = (candidate: typeof contextRef.current) => contextRef.current.gateway === candidate.gateway && contextRef.current.enabled === candidate.enabled && contextRef.current.disabled === candidate.disabled && contextRef.current.refreshKey === candidate.refreshKey && contextRef.current.destinationPath === candidate.destinationPath;
  const discard = (candidate: RssSnapshotBackupPlan | null, boundGateway = gateway) => { if (candidate) void boundGateway.discardRssSnapshotBackup(candidate.planId).catch(() => undefined); };
  const current = usable && planRef.current === plan && planContextRef.current !== null && sameContext(planContextRef.current) && validPlan(plan, destinationPath ?? "") ? plan : null;

  useEffect(() => { const old = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(old, oldGateway); generation.current += 1; busyRef.current = false; setPlan(null); consentRef.current = false; setConsent(false); setBusy(null); setError(""); setMessage(null); return () => { const currentPlan = planRef.current; const gatewayForOld = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(currentPlan, gatewayForOld); generation.current += 1; busyRef.current = false; }; }, [gateway, enabled, disabled, refreshKey]);
  useEffect(() => { if (!current) return; const timer = window.setTimeout(() => { if (planRef.current !== current) return; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(current, oldGateway); setPlan(null); consentRef.current = false; setConsent(false); setError("计划已过期，请重新生成。"); }, Math.max(0, current.expiresAtEpochMs - Date.now())); return () => window.clearTimeout(timer); }, [current?.planId, current?.expiresAtEpochMs]);
  function invalidate() { const old = planRef.current; const oldGateway = planContextRef.current?.gateway; planRef.current = null; planContextRef.current = null; discard(old, oldGateway); generation.current += 1; setPlan(null); consentRef.current = false; setConsent(false); setError(""); setMessage(null); }

  async function choose() { if (!usable || busyRef.current) return; invalidate(); setDestinationPath(null); const request = ++generation.current; const requestContext = { ...contextRef.current, destinationPath: null }; busyRef.current = true; setBusy("selecting"); try { const next = await gateway.selectRssSnapshotBackupDestination(); if (request !== generation.current || !sameContext(requestContext) || !usable) return; if (next !== null && !absoluteSqlite(next)) throw new Error("invalid"); if (next !== null) setDestinationPath(next); } catch { if (request === generation.current && sameContext(requestContext)) setError("无法选择新的 SQLite 文件路径，请选择新的绝对 .sqlite 文件路径。"); } finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } } }
  async function prepare() { const path = destinationPath; if (!usable || busyRef.current || !path || !absoluteSqlite(path)) return; invalidate(); const request = ++generation.current; const requestContext = contextRef.current; busyRef.current = true; setBusy("planning"); try { const next: unknown = await gateway.planRssSnapshotBackup(path); if (request !== generation.current || !sameContext(requestContext) || !usable || destinationPath !== path) { if (next && typeof next === "object" && uuid((next as Partial<RssSnapshotBackupPlan>).planId)) discard(next as RssSnapshotBackupPlan, requestContext.gateway); return; } if (!validPlan(next, path)) { const invalid = next && typeof next === "object" ? next as Partial<RssSnapshotBackupPlan> : null; if (invalid && uuid(invalid.planId)) discard(invalid as RssSnapshotBackupPlan, requestContext.gateway); throw new Error("invalid"); } planRef.current = next; planContextRef.current = requestContext; setPlan(next); } catch { if (request === generation.current && sameContext(requestContext)) setError("无法生成 RSS 快照预览，请确认目的地是新的绝对 .sqlite 文件路径。"); } finally { if (request === generation.current && sameContext(requestContext)) { busyRef.current = false; setBusy(null); } } }
  async function execute() { const captured = current; const capturedContext = planContextRef.current; if (!usable || disabled || busyRef.current || !captured || !capturedContext || planRef.current !== captured || !sameContext(capturedContext) || !consentRef.current || captured.expiresAtEpochMs <= Date.now()) return; planRef.current = null; planContextRef.current = null; consentRef.current = false; setPlan(null); setConsent(false); busyRef.current = true; setBusy("exporting"); setError(""); setMessage(null); const request = ++generation.current; try { const result: unknown = await gateway.executeRssSnapshotBackup(captured.planId, true); if (request !== generation.current || !sameContext(capturedContext) || !validResult(result, captured)) throw new Error("invalid"); setMessage({ source: "已导出并核验本地 SQLite 文件：{path}；SHA-256：{sha}。", parameters: { path: captured.destinationPath, sha: captured.sha256 } }); } catch { if (request === generation.current && sameContext(capturedContext)) setError("RSS 快照导出结果未明；计划已消耗，不会自动重试。文件可能已存在，请查验后选择新路径。"); } finally { if (request === generation.current && sameContext(capturedContext)) { busyRef.current = false; setBusy(null); } } }

  return <section className="operation-plan" aria-label={t("RSS 数据库快照")} aria-busy={busy !== null}>
    <h4>{t("RSS 数据库快照")}</h4>
    <p className="publish-muted">{t("这是 RSS 单库的一致快照，不是全工作区备份、恢复授权或 macOS 版交换格式。预览会在本机读取 RSS 正文，但只显示数量、大小和 SHA，不显示正文或 URL。文件上限为 32 MiB；来源变化后需重新预览。")}</p>
    <p className="publish-warning">{t("快照可能包含文章、URL、笔记、阅读进度、缓存、离线翻译、翻译服务与模型信息和临时撤销内容等敏感明文，内容可能自带秘密且不会自动脱敏。凭据存储、其他工作区来源和外部附件独立排除。来源复制会压缩副本，不会清理原库。")}</p>
    <button type="button" onClick={() => void choose()} disabled={!usable || busy !== null}>{t("选择新的 SQLite 文件路径")}</button>
    {destinationPath && <p>{t("目标路径：{path}", { path: destinationPath })}</p>}
    {destinationPath && <button type="button" onClick={() => void prepare()} disabled={!usable || busy !== null}>{t("明确预览 RSS 快照")}</button>}
    {busy === "selecting" && <p role="status">{t("正在选择路径…")}</p>}{busy === "planning" && <p role="status">{t("正在生成 RSS 快照预览…")}</p>}{busy === "exporting" && <p role="status">{t("正在导出并核验 SQLite 文件…")}</p>}
    {error && <p role="alert" className="publish-warning">{t(error)}</p>}{message && <p role="status">{renderBackupExportMessage(message, locale, t)}</p>}
    {current && <div className="operation-plan">
      <p><strong>{t("RSS 快照预览（一次性，5 分钟内有效）")}</strong></p>
      {current.tables.map((item) => <p key={item.table}>{t("{table}：{count} 条", { table: t(tableLabels[item.table]), count: number(item.rowCount) })}</p>)}
      <p>{t("大小：{bytes} 字节；SHA-256：{sha}", { bytes: number(current.byteSize), sha: current.sha256 })}</p>
      <p>{t("有效至：{date}", { date: date(current.expiresAtEpochMs) })}</p>
      <p>{t("固定排除：{exclusions}", { exclusions: list(current.exclusions.map((item) => t(exclusionLabels[item]))) })}</p>
      <label htmlFor="rss-snapshot-backup-consent"><input id="rss-snapshot-backup-consent" type="checkbox" checked={consent} onChange={(event) => { consentRef.current = event.target.checked; setConsent(event.target.checked); }} disabled={busy !== null || !usable} />{t("我已知悉并同意导出敏感 RSS 明文")}</label>
      <button type="button" onClick={() => void execute()} disabled={!usable || disabled || busy !== null || !consent}>{t("明确一次性导出 RSS 快照")}</button>
      <button type="button" onClick={invalidate} disabled={busy !== null}>{t("取消 RSS 快照计划")}</button>
    </div>}
  </section>;
}
