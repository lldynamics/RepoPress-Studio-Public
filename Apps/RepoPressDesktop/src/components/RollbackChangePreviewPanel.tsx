import { useEffect, useRef, useState } from "react";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type {
  RollbackChangePreview,
  RollbackChangePreviewGateway,
  RollbackFileChange,
  RollbackFileIssue,
  RollbackPreviewWarning,
} from "../contracts/rollbackChangePreview";
import type { RollbackBlocker } from "../contracts/rollbackQualification";
import { useI18n } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";

export interface RollbackChangePreviewPanelProps {
  gateway: RollbackChangePreviewGateway;
  sessionId: string;
  entry: ReleaseLedgerEntry;
  enabled: boolean;
  disabled?: boolean;
}

const blockerLabels: Record<RollbackBlocker, string> = {
  recordUnconfirmed: "推送记录未核实", objectsUnavailable: "本地对象不可用", rootCommit: "目标是根提交，缺少父提交",
  mergeCommit: "目标是合并提交", targetChanged: "目标分支或远端已变化", evidenceMismatch: "证据不一致",
  remoteDifferent: "远端头与目标不同", remoteUnavailable: "远端头不可查询",
};
const warningLabels: Record<RollbackPreviewWarning, string> = {
  entryLimit: "条目数量达到上限", treeLimit: "树遍历达到上限", timeLimit: "读取时间达到上限", byteLimit: "对象字节达到上限",
  unsafePathsOmitted: "不安全路径已省略", objectsUnavailable: "对象不可用", unsupportedTypes: "包含不支持的对象类型",
};
const issueLabels: Record<RollbackFileIssue, string> = {
  unsupportedType: "不支持的类型", objectMissing: "对象缺失", objectTooLarge: "对象过大", objectHashMismatch: "对象哈希不匹配", budgetLimit: "预算限制",
};
const actions = { delete: "删除", restore: "恢复", replace: "替换", unsupported: "不支持" } as const;
const sha = (value: unknown): value is string => typeof value === "string" && (value.length === 40 || value.length === 64) && /^[0-9a-f]+$/.test(value);
const owns = (record: object, key: PropertyKey): boolean => Object.prototype.hasOwnProperty.call(record, key);
const safePath = (value: unknown): value is string => typeof value === "string" && value.length > 0 && new TextEncoder().encode(value).length <= 4096
  && !/[\u0000-\u001f\u007f\u0080-\u009f\\:<>"|?*]/.test(value) && !value.startsWith("/") && !/^[A-Za-z]:/.test(value)
  && !value.split("/").some((part) => {
    const stem = part.split(".", 1)[0].toUpperCase();
    return part.length === 0 || part === "." || part === ".." || part.toUpperCase() === ".GIT" || /[. ]$/.test(part)
      || ["CON", "PRN", "AUX", "NUL"].includes(stem) || /^(COM|LPT)[1-9]$/.test(stem);
  });
const side = (value: unknown): value is { mode: string; objectId: string; byteSize: number | null } => {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return typeof v.mode === "string" && ["040000", "100644", "100755", "120000", "160000"].includes(v.mode) && sha(v.objectId)
    && (v.byteSize === null || (typeof v.byteSize === "number" && Number.isSafeInteger(v.byteSize) && v.byteSize >= 0 && v.byteSize <= 65536));
};
const unique = <T,>(items: T[]) => new Set(items).size === items.length;
const identityKey = (sessionId: string, entry: ReleaseLedgerEntry) => [sessionId, entry.source, entry.recordId, entry.revision, entry.operation, entry.branch, entry.targetBranch ?? "", entry.remoteUrl, entry.expectedSha, entry.status, entry.checkedAtEpochMs ?? "null"].join("\u0000");
const validIdentity = (value: RollbackChangePreview, sessionId: string, entry: ReleaseLedgerEntry) => value.sessionId === sessionId && value.recordId === entry.recordId
  && value.revision === entry.revision && value.branch === entry.branch && value.remoteUrl === entry.remoteUrl && value.expectedSha === entry.expectedSha
  && (value.parentSha === null || sha(value.parentSha));
function validChange(change: unknown): change is RollbackFileChange {
  if (!change || typeof change !== "object") return false;
  const v = change as Record<string, unknown>; const action = v.action;
  if (!safePath(v.path) || !["delete", "restore", "replace", "unsupported"].includes(String(action)) || !["verified", "unavailable", "unsupported"].includes(String(v.verification))) return false;
  if (v.published !== null && !side(v.published) || v.restore !== null && !side(v.restore)) return false;
  if (!Array.isArray(v.issues) || !unique(v.issues) || !v.issues.every((i) => typeof i === "string" && owns(issueLabels, i))) return false;
  if (action === "delete" && (!v.published || v.restore !== null) || action === "restore" && (v.published !== null || !v.restore)
    || action === "replace" && (!v.published || !v.restore) || action === "unsupported" && v.verification === "verified") return false;
  const sides = [v.published, v.restore].filter(Boolean) as { mode: string; byteSize: number | null }[];
  const regular = sides.every((s) => ["100644", "100755"].includes(s.mode));
  if (["delete", "restore", "replace"].includes(String(action)) && !regular) return false;
  if (v.verification === "verified" && (action === "unsupported" || !v.published && !v.restore || v.issues.length !== 0 || !regular || sides.some((s) => s.byteSize === null))) return false;
  if (v.verification === "unavailable" && (sides.length === 0 || v.issues.length === 0 || v.issues.includes("unsupportedType") || sides.every((s) => s.byteSize !== null))) return false;
  if (action === "unsupported" || v.verification === "unsupported") {
    if (action !== "unsupported" || v.verification !== "unsupported" || v.issues.length !== 1 || v.issues[0] !== "unsupportedType" || sides.length === 0
      || regular || sides.some((s) => s.byteSize !== null)) return false;
  }
  return true;
}
function validPreview(value: unknown, sessionId: string, entry: ReleaseLedgerEntry): value is RollbackChangePreview {
  if (!value || typeof value !== "object") return false; const v = value as RollbackChangePreview;
  if (!validIdentity(v, sessionId, entry) || !["complete", "partial", "blocked"].includes(v.status) || !Number.isSafeInteger(v.checkedAtEpochMs) || v.checkedAtEpochMs <= 0
    || !Array.isArray(v.changes) || v.changes.length > 200 || !v.changes.every(validChange) || new Set(v.changes.map((c) => c.path)).size !== v.changes.length
    || !(v.omittedPaths === null || (Number.isSafeInteger(v.omittedPaths) && v.omittedPaths >= 0)) || !Array.isArray(v.blockers) || !unique(v.blockers) || !v.blockers.every((b) => typeof b === "string" && owns(blockerLabels, b))
    || !Array.isArray(v.warnings) || !unique(v.warnings) || !v.warnings.every((w) => typeof w === "string" && owns(warningLabels, w)) || !v.summary || typeof v.summary !== "object") return false;
  const summary = { visible: v.changes.length, deleteFiles: v.changes.filter((c) => c.action === "delete").length, restoreFiles: v.changes.filter((c) => c.action === "restore").length, replaceFiles: v.changes.filter((c) => c.action === "replace").length, unsupportedFiles: v.changes.filter((c) => c.action === "unsupported").length, verifiedFiles: v.changes.filter((c) => c.verification === "verified").length };
  if (JSON.stringify(v.summary) !== JSON.stringify(summary)) return false;
  if (v.status === "complete") return entry.source === "gitPush" && entry.status === "pushVerified" && entry.checkedAtEpochMs !== null && sha(v.parentSha) && v.omittedPaths === 0 && v.warnings.length === 0 && v.blockers.length === 0 && v.changes.every((c) => c.verification === "verified");
  if (v.status === "partial") return entry.source === "gitPush" && entry.status === "pushVerified" && entry.checkedAtEpochMs !== null && sha(v.parentSha) && v.blockers.length === 0 && v.warnings.length > 0 && (v.omittedPaths !== 0 || v.changes.some((c) => c.verification !== "verified"));
  return v.changes.length === 0 && v.omittedPaths === null && v.warnings.length === 0 && v.blockers.length > 0
    && !v.blockers.includes("remoteDifferent") && !v.blockers.includes("remoteUnavailable") && (v.parentSha === null || sha(v.parentSha));
}

export function RollbackChangePreviewPanel({ gateway, sessionId, entry, enabled, disabled = false }: RollbackChangePreviewPanelProps) {
  const { locale, t } = useI18n();
  const [preview, setPreview] = useState<RollbackChangePreview | null>(null); const [error, setError] = useState<UiMessage | null>(null); const [busy, setBusy] = useState(false); const [page, setPage] = useState(0);
  const generation = useRef(0); const busyRef = useRef(false); const key = identityKey(sessionId, entry); const usable = enabled && !disabled && Boolean(sessionId) && entry.source === "gitPush";
  useEffect(() => { generation.current += 1; busyRef.current = false; setPreview(null); setError(null); setBusy(false); setPage(0); return () => { generation.current += 1; busyRef.current = false; }; }, [gateway, key, enabled, disabled]);
  async function inspect() {
    if (!usable || busyRef.current) return; busyRef.current = true; const request = ++generation.current; setBusy(true); setError(null); setPreview(null); setPage(0);
    try { const next = await gateway.inspectRollbackChanges(sessionId, entry.recordId, entry.revision); if (request !== generation.current) return; if (!validPreview(next, sessionId, entry)) throw new Error("invalid response"); setPreview(next); }
    catch { if (request === generation.current) setError({ source: "无法读取单提交逆向变更预览。" }); }
    finally { if (request === generation.current) { busyRef.current = false; setBusy(false); } }
  }
  const rows = preview?.changes.slice(page * 50, page * 50 + 50) ?? []; const pages = preview ? Math.max(1, Math.ceil(preview.changes.length / 50)) : 0;
  const formatSide = (value: { mode: string; objectId: string; byteSize: number | null } | null) => value ? t("{kind} {mode} / {objectId} / {byteSize} B", { kind: t(value.mode === "040000" ? "目录" : "文件"), mode: value.mode, objectId: value.objectId, byteSize: value.byteSize ?? t("未知") }) : "—";
  const labels = (items: string[], map: Record<string, string>) => items.length ? items.map((i) => t(map[i] ?? i)).join(t("、")) : t("无");
  return <section className="operation-plan" aria-label={t("单个冻结提交逆向变更预览")} aria-busy={busy}>
    <h4>{t("单提交逆向变更预览")}</h4><p className="publish-muted">{t("仅针对单个冻结提交相对父提交；不是整次多提交推送。对象检查不证明可直接回滚、当前远端状态或无冲突。")}</p>
    <button type="button" onClick={() => void inspect()} disabled={!usable || busy}>{t("预览单提交逆向变更")}</button>{busy && <p role="status" className="publish-muted">{t("正在读取本地对象…")}</p>}{error && <p role="alert" className="publish-warning">{renderUiMessage(error, t)}</p>}
    {preview && <div><p><strong>{t(preview.status === "complete" ? "预览完整" : preview.status === "partial" ? "预览部分可用" : "预览被阻塞")}</strong></p>{preview.status === "complete" && <p className="publish-muted">{t("仅核验变化路径所需对象；未逐一核验未变化文件对象。")}</p>}<dl><dt>{t("冻结 SHA")}</dt><dd>{preview.expectedSha}</dd><dt>{t("父 SHA")}</dt><dd>{preview.parentSha ?? t("无")}</dd><dt>{t("检查时间")}</dt><dd>{new Date(preview.checkedAtEpochMs).toLocaleString(locale)}</dd><dt>{t("摘要")}</dt><dd>{t("可见 {visible}，删除 {deleteFiles}，恢复 {restoreFiles}，替换 {replaceFiles}，不支持 {unsupportedFiles}，已核实 {verifiedFiles}", preview.summary)}</dd></dl>{preview.status === "blocked" && <p className="publish-warning">{t("阻塞原因：{blockers}", { blockers: labels(preview.blockers, blockerLabels) })}</p>}{preview.status !== "complete" && <p className="publish-warning">{t("警告：{warnings}；省略路径：{omitted}", { warnings: labels(preview.warnings, warningLabels), omitted: preview.omittedPaths ?? t("未知") })}</p>}
      {rows.length > 0 && <><table><thead><tr><th>{t("路径")}</th><th>{t("方向")}</th><th>{t("已发布（冻结提交）")}</th><th>{t("恢复（父提交）")}</th><th>{t("核实")}</th><th>{t("问题")}</th></tr></thead><tbody>{rows.map((row) => <tr key={row.path}><td>{row.path}</td><td>{t(actions[row.action])}</td><td>{formatSide(row.published)}</td><td>{formatSide(row.restore)}</td><td>{t(row.verification === "verified" ? "已核实" : row.verification === "unsupported" ? "不支持" : "不可用")}</td><td>{row.issues.length ? row.issues.map((i) => t(issueLabels[i])).join(t("、")) : t("无")}</td></tr>)}</tbody></table>{pages > 1 && <p><button type="button" onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0}>{t("上一页")}</button> {t("第 {page}/{pages} 页", { page: page + 1, pages })} <button type="button" onClick={() => setPage((p) => Math.min(pages - 1, p + 1))} disabled={page === pages - 1}>{t("下一页")}</button></p>}</>}
    </div>}
  </section>;
}
