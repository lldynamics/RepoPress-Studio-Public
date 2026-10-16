import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import type { DocumentSnapshot, DraftVersion, DraftVersionSummary, RecycledDraft, RecycledDraftSummary, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { compareDraftSections } from "../features/writing/draftComparison";
import { DraftVersionComparisonView } from "./DraftVersionComparisonView";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { useI18n, type MessageParameters, type UiTranslator } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { draftHistoryMessages } from "../i18n/draftHistoryMessages";
import "./DraftHistoryCenter.css";

export interface DraftHistoryCenterProps {
  open: boolean;
  onClose: () => void;
  gateway: RepositoryGateway;
  repository: RepositorySessionSnapshot | null;
  document: DocumentSnapshot | null;
  currentText: string;
  onRestoreDocument: (snapshot: DocumentSnapshot, source: "version" | "recycle") => void | Promise<void>;
}

type HistoryTab = "versions" | "recycle";
type LoadedVersion = { key: string; version: DraftVersion };
type TargetError = { key: string; error: HistoryError };

type ControlledMessage = { source: string; parameters?: MessageParameters };
type HistoryError = { kind: "raw"; text: string } | { kind: "controlled"; source: string };

function errorMessage(reason: unknown, fallback: string): HistoryError {
  if (reason && typeof reason === "object" && "message" in reason && typeof reason.message === "string") return { kind: "raw", text: reason.message };
  return { kind: "controlled", source: fallback };
}

function formatTime(value: number, locale: UiLocale, t: UiTranslator): string {
  const date = new Date(value * 1_000);
  return Number.isFinite(date.getTime()) ? date.toLocaleString(locale) : t("时间未知");
}

function formatSize(value: number): string {
  if (value < 1_024) return `${value} B`;
  if (value < 1_048_576) return `${(value / 1_024).toFixed(1)} KB`;
  return `${(value / 1_048_576).toFixed(1)} MB`;
}

function versionReason(reason: DraftVersionSummary["reason"]): string {
  if (reason === "beforeRestore") return "恢复前";
  if (reason === "deleted") return "删除前";
  return "保存前";
}

function historyContextKey(repository: RepositorySessionSnapshot | null, document: DocumentSnapshot | null): string | null {
  return repository && document ? JSON.stringify([repository.sessionId, repository.rootPath, document.documentId, document.relativePath, document.baselineSha256, document.revision]) : null;
}

function versionKey(repository: RepositorySessionSnapshot | null, document: DocumentSnapshot | null, versionId: string | null): string | null {
  const context = historyContextKey(repository, document);
  return context && versionId ? JSON.stringify([context, versionId]) : null;
}

function sortNewest<T extends { createdAtEpochSeconds?: number; deletedAtEpochSeconds?: number }>(items: readonly T[]): T[] {
  return [...items].sort((left, right) => (right.createdAtEpochSeconds ?? right.deletedAtEpochSeconds ?? 0) - (left.createdAtEpochSeconds ?? left.deletedAtEpochSeconds ?? 0));
}

export function DraftHistoryCenter({ open, onClose, gateway, repository, document, currentText, onRestoreDocument }: DraftHistoryCenterProps) {
  const { locale, t } = useI18n(draftHistoryMessages);
  const root = useRef<HTMLDivElement>(null);
  const requestGeneration = useRef(0);
  const detailGeneration = useRef(0);
  const targetGeneration = useRef(0);
  const [tab, setTab] = useState<HistoryTab>("versions");
  const [versions, setVersions] = useState<DraftVersionSummary[]>([]);
  const [versionsContext, setVersionsContext] = useState<string | null>(null);
  const [recycled, setRecycled] = useState<RecycledDraftSummary[]>([]);
  const [selectedVersion, setSelectedVersion] = useState<string | null>(null);
  const [selectedRecycle, setSelectedRecycle] = useState<string | null>(null);
  const [versionDetail, setVersionDetail] = useState<LoadedVersion | null>(null);
  const [comparisonTarget, setComparisonTarget] = useState<string | null>(null);
  const [targetDetail, setTargetDetail] = useState<LoadedVersion | null>(null);
  const [targetError, setTargetError] = useState<TargetError | null>(null);
  const [recycleDetail, setRecycleDetail] = useState<RecycledDraft | null>(null);
  const [restorePath, setRestorePath] = useState("");
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<HistoryError | null>(null);
  const [status, setStatus] = useState<ControlledMessage | null>(null);
  const titleId = useId();
  const dirty = Boolean(document && currentText !== document.text);
  const close = useCallback(() => { if (!busy) onClose(); }, [busy, onClose]);
  useDrawerFocus(open, root, close);

  const activeVersions = versionsContext === historyContextKey(repository, document) ? versions : [];
  const targetVersionId = comparisonTarget && comparisonTarget !== selectedVersion && activeVersions.some((item) => item.versionId === comparisonTarget) ? comparisonTarget : null;
  const sourceKey = activeVersions.some((item) => item.versionId === selectedVersion) ? versionKey(repository, document, selectedVersion) : null;
  const targetKey = sourceKey && targetVersionId ? JSON.stringify([sourceKey, versionKey(repository, document, targetVersionId)]) : null;
  const sourceVersion = sourceKey && versionDetail?.key === sourceKey ? versionDetail.version : null;
  const targetVersion = targetKey && targetDetail?.key === targetKey ? targetDetail.version : null;
  const targetFailure = targetKey && targetError?.key === targetKey ? targetError.error : null;
  const targetPending = Boolean(open && tab === "versions" && targetVersionId && !targetVersion && !targetFailure);
  const targetText = targetVersionId ? targetVersion?.text ?? null : currentText;
  const comparison = useMemo(() => sourceVersion && targetText !== null ? compareDraftSections(targetText, sourceVersion.text) : null, [sourceVersion, targetText]);

  const loadVersions = useCallback(async () => {
    if (!repository || !document) return;
    const generation = ++requestGeneration.current;
    setLoading(true); setError(null); setVersionDetail(null);
    try {
      const snapshot = await gateway.listDraftVersions(repository.sessionId, document.documentId);
      if (generation !== requestGeneration.current) return;
      const next = sortNewest(snapshot.versions);
      setVersions(next); setVersionsContext(historyContextKey(repository, document));
      setSelectedVersion((current) => next.some((item) => item.versionId === current) ? current : next[0]?.versionId ?? null);
    } catch (reason) {
      if (generation === requestGeneration.current) { setVersions([]); setVersionsContext(null); setSelectedVersion(null); setError(errorMessage(reason, "无法读取版本历史。")); }
    } finally { if (generation === requestGeneration.current) setLoading(false); }
  }, [document, gateway, repository]);

  const loadRecycle = useCallback(async () => {
    if (!repository) return;
    const generation = ++requestGeneration.current;
    setLoading(true); setError(null); setRecycleDetail(null);
    try {
      const snapshot = await gateway.listRecycledDrafts(repository.sessionId);
      if (generation !== requestGeneration.current) return;
      const next = sortNewest(snapshot.entries);
      setRecycled(next);
      setSelectedRecycle((current) => next.some((item) => item.recycleId === current) ? current : next[0]?.recycleId ?? null);
      if (snapshot.truncated) setStatus({ source: "仅显示最近 {count} 条回收记录。", parameters: { count: next.length } });
    } catch (reason) {
      if (generation === requestGeneration.current) { setRecycled([]); setSelectedRecycle(null); setError(errorMessage(reason, "无法读取回收站。")); }
    } finally { if (generation === requestGeneration.current) setLoading(false); }
  }, [gateway, repository]);

  useEffect(() => {
    requestGeneration.current += 1; detailGeneration.current += 1; targetGeneration.current += 1;
    setError(null); setStatus(null); setVersions([]); setVersionsContext(null); setRecycled([]); setSelectedVersion(null); setSelectedRecycle(null); setVersionDetail(null); setRecycleDetail(null); setRestorePath("");
    setComparisonTarget(null); setTargetDetail(null); setTargetError(null);
    if (!open) return;
    if (tab === "versions") void loadVersions(); else void loadRecycle();
  }, [document?.documentId, loadRecycle, loadVersions, open, repository?.sessionId, tab]);

  useEffect(() => {
    if (!open || tab !== "versions" || !repository || !document || !selectedVersion || !sourceKey) return;
    const generation = ++detailGeneration.current;
    setVersionDetail(null); setError(null);
    void gateway.getDraftVersion(repository.sessionId, document.documentId, selectedVersion).then((version) => {
      if (generation !== detailGeneration.current) return;
      setVersionDetail({ key: sourceKey, version });
    }).catch((reason: unknown) => { if (generation === detailGeneration.current) setError(errorMessage(reason, "无法读取该版本。")); });
    return () => { detailGeneration.current += 1; };
  }, [document, gateway, open, repository, selectedVersion, sourceKey, tab, versions]);

  useEffect(() => {
    if (comparisonTarget !== null && comparisonTarget !== targetVersionId) setComparisonTarget(null);
  }, [comparisonTarget, targetVersionId]);

  useEffect(() => {
    const generation = ++targetGeneration.current;
    setTargetDetail(null); setTargetError(null);
    if (!open || tab !== "versions" || !repository || !document || !targetVersionId || !targetKey) return;
    void gateway.getDraftVersion(repository.sessionId, document.documentId, targetVersionId).then((version) => {
      if (generation === targetGeneration.current) setTargetDetail({ key: targetKey, version });
    }).catch((reason: unknown) => {
      if (generation === targetGeneration.current) setTargetError({ key: targetKey, error: errorMessage(reason, "无法读取对比版本。") });
    });
    return () => { targetGeneration.current += 1; };
  }, [document, gateway, open, repository, selectedVersion, tab, targetKey, targetVersionId]);

  useEffect(() => {
    if (!open || tab !== "recycle" || !repository || !selectedRecycle) return;
    const generation = ++detailGeneration.current;
    setRecycleDetail(null); setRestorePath(""); setError(null);
    void gateway.getRecycledDraft(repository.sessionId, selectedRecycle).then((entry) => {
      if (generation !== detailGeneration.current) return;
      setRecycleDetail(entry); setRestorePath(entry.relativePath);
    }).catch((reason: unknown) => { if (generation === detailGeneration.current) setError(errorMessage(reason, "无法读取回收条目。")); });
  }, [gateway, open, repository, selectedRecycle, tab]);

  const selectedVersionSummary = useMemo(() => activeVersions.find((item) => item.versionId === selectedVersion) ?? null, [activeVersions, selectedVersion]);
  const selectedRecycleSummary = useMemo(() => recycled.find((item) => item.recycleId === selectedRecycle) ?? null, [recycled, selectedRecycle]);
  const repositoryReadOnly = Boolean(document && !document.writable);
  const restoreDisabled = busy || dirty || repositoryReadOnly || !document || !sourceKey;

  async function restoreVersion() {
    if (!repository || !document || !selectedVersion || restoreDisabled) return;
    if (!window.confirm(t("恢复到所选版本？当前已保存内容会先保留为一个版本。"))) return;
    setBusy(true); setError(null); setStatus({ source: "正在恢复版本…" });
    try {
      const restored = await gateway.restoreDraftVersion(repository.sessionId, document.documentId, selectedVersion, document.baselineSha256);
      await onRestoreDocument(restored, "version");
      setStatus({ source: "已恢复所选版本。" });
      await loadVersions();
    } catch (reason) { setError(errorMessage(reason, "恢复版本失败，当前文章未被切换。")); setStatus(null); }
    finally { setBusy(false); }
  }

  async function restoreRecycle() {
    const path = restorePath.trim();
    if (!repository || !selectedRecycle || !path || busy || dirty || repositoryReadOnly) return;
    if (!window.confirm(t("恢复“{source}”到“{path}”？", { source: selectedRecycleSummary?.relativePath ?? path, path }))) return;
    setBusy(true); setError(null); setStatus({ source: "正在恢复回收文章…" });
    try {
      const restored = await gateway.restoreRecycledDraft(repository.sessionId, selectedRecycle, path);
      await onRestoreDocument(restored, "recycle");
      setStatus({ source: "文章已从回收站恢复。" });
      await loadRecycle();
    } catch (reason) { setError(errorMessage(reason, "恢复回收文章失败。")); setStatus(null); }
    finally { setBusy(false); }
  }

  async function permanentlyDelete() {
    if (!repository || !selectedRecycle || busy || repositoryReadOnly) return;
    const name = selectedRecycleSummary?.relativePath ?? t("该回收条目");
    if (!window.confirm(t("永久删除“{name}”？", { name }))) return;
    if (!window.confirm(t("此操作不可恢复。确定要永久删除吗？"))) return;
    setBusy(true); setError(null); setStatus({ source: "正在永久删除…" });
    try {
      await gateway.deleteRecycledDraft(repository.sessionId, selectedRecycle);
      setStatus({ source: "已永久删除回收条目。" });
      await loadRecycle();
    } catch (reason) { setError(errorMessage(reason, "永久删除失败。")); setStatus(null); }
    finally { setBusy(false); }
  }

  const errorText = error ? error.kind === "raw" ? error.text : t(error.source) : "";
  const targetErrorText = targetFailure ? targetFailure.kind === "raw" ? targetFailure.text : t(targetFailure.source) : "";

  if (!open) return null;

  return <div ref={root} className="draft-history-scrim" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) close(); }}>
    <section className="draft-history-center" role="dialog" aria-modal="true" aria-labelledby={titleId} aria-busy={loading || busy || targetPending} tabIndex={-1}>
      <header className="draft-history-center__header">
        <div><h2 id={titleId}>{t("版本历史与回收站")}</h2><p>{repository ? t("{name} 的本地文章保护记录", { name: repository.displayName }) : t("请先打开一个仓库。")}</p></div>
        <button type="button" className="draft-history-center__close" onClick={close} disabled={busy} aria-label={t("关闭版本历史与回收站")}>×</button>
      </header>
      <div className="draft-history-center__tabs" role="tablist" aria-label={t("草稿生命周期")}>
        <button id="draft-history-versions-tab" type="button" role="tab" aria-selected={tab === "versions"} aria-controls="draft-history-versions" onClick={() => setTab("versions")} disabled={busy}>{t("版本历史")}</button>
        <button id="draft-history-recycle-tab" type="button" role="tab" aria-selected={tab === "recycle"} aria-controls="draft-history-recycle" onClick={() => setTab("recycle")} disabled={busy}>{t("回收站")}</button>
      </div>
      <div className="draft-history-center__body">
        {tab === "versions" ? <section id="draft-history-versions" role="tabpanel" aria-labelledby="draft-history-versions-tab" className="draft-history-center__panel">
          {!repository ? <EmptyState text={t("请先选择一个仓库以查看保护记录。")} /> : !document ? <EmptyState text={t("打开一篇文章后，可在这里查看它保存或恢复前的版本。")} /> : <>
            {dirty && <p className="draft-history-center__notice">{t("当前文章有未保存修改。浏览和比较仍可使用；请先保存或重新打开后再恢复，避免覆盖编辑缓冲区。")}</p>}
            <HistoryList locale={locale} t={t} items={activeVersions} selectedId={selectedVersion} busy={busy} loading={loading} onSelect={setSelectedVersion} />
            {selectedVersionSummary && <article className="draft-history-center__detail">
              <div className="draft-history-center__comparison-heading">
                <div><p className="draft-history-center__source-label">{t("所选版本")}</p><h3>{t(versionReason(selectedVersionSummary.reason))} · {formatTime(selectedVersionSummary.createdAtEpochSeconds, locale, t)}</h3><p>{formatSize(selectedVersionSummary.byteSize)} · {selectedVersionSummary.contentSha256.slice(0, 12)}</p></div>
                <label className="draft-history-center__target"><span>{t("对比目标")}</span><select disabled={busy} value={targetVersionId ? `version:${targetVersionId}` : "current"} onChange={(event) => { if (!busy) setComparisonTarget(event.target.value === "current" ? null : event.target.value.slice("version:".length)); }}>
                  <option value="current">{t("当前稿")}</option>
                  {activeVersions.filter((item) => item.versionId !== selectedVersion).map((item) => <option key={item.versionId} value={`version:${item.versionId}`}>{t(versionReason(item.reason))} · {formatTime(item.createdAtEpochSeconds, locale, t)} · {item.contentSha256.slice(0, 8)}</option>)}
                </select></label>
              </div>
              <p className="draft-history-center__comparison-hint">{t("恢复操作仍指向所选版本。")}</p>
              {targetErrorText && <p className="draft-history-center__error" role="alert">{targetErrorText}</p>}
              {comparison ? <DraftVersionComparisonView key={targetKey ?? sourceKey} comparison={comparison} targetKind={targetVersionId ? "version" : "current"} /> : <p className="draft-history-center__loading">{targetFailure ? t("请选择其他对比目标。") : !sourceVersion ? t("正在加载版本比较…") : t("正在读取对比版本…")}</p>}
            </article>}
          </>}
        </section> : <section id="draft-history-recycle" role="tabpanel" aria-labelledby="draft-history-recycle-tab" className="draft-history-center__panel">
          {!repository ? <EmptyState text={t("请先选择一个仓库以查看回收站。")} /> : <>
            <RecycleList locale={locale} t={t} items={recycled} selectedId={selectedRecycle} busy={busy} loading={loading} onSelect={setSelectedRecycle} />
            {selectedRecycleSummary && <article className="draft-history-center__detail"><h3>{selectedRecycleSummary.relativePath}</h3><p>{t("删除于 {time} · {size}", { time: formatTime(selectedRecycleSummary.deletedAtEpochSeconds, locale, t), size: formatSize(selectedRecycleSummary.byteSize) })}</p>{recycleDetail ? <><label className="draft-history-center__path"><span>{t("恢复到仓库内路径")}</span><input value={restorePath} disabled={busy || dirty || repositoryReadOnly} spellCheck={false} autoComplete="off" onChange={(event) => setRestorePath(event.target.value)} /></label><pre aria-label={t("回收文章预览")}>{recycleDetail.text}</pre></> : <p className="draft-history-center__loading">{t("正在读取回收文章…")}</p>}</article>}
          </>}
        </section>}
        {errorText && <p className="draft-history-center__error" role="alert">{errorText}</p>}
        <p className="draft-history-center__status" aria-live="polite">{status ? t(status.source, status.parameters) : ""}</p>
      </div>
      <footer className="draft-history-center__footer">
        <button type="button" onClick={close} disabled={busy}>{t("关闭")}</button><span />
        {tab === "versions" ? <button type="button" className="primary" onClick={() => void restoreVersion()} disabled={!selectedVersion || restoreDisabled}>{t("恢复所选版本")}</button> : <><button type="button" className="danger" onClick={() => void permanentlyDelete()} disabled={!selectedRecycle || busy || repositoryReadOnly}>{t("永久删除")}</button><button type="button" className="primary" onClick={() => void restoreRecycle()} disabled={!selectedRecycle || !restorePath.trim() || busy || dirty || repositoryReadOnly}>{t("恢复文章")}</button></>}
      </footer>
    </section>
  </div>;
}

function EmptyState({ text }: { text: string }) { return <p className="draft-history-center__empty">{text}</p>; }

function HistoryList({ items, selectedId, loading, busy, onSelect, locale, t }: { locale: UiLocale; t: UiTranslator; items: DraftVersionSummary[]; selectedId: string | null; loading: boolean; busy: boolean; onSelect: (id: string) => void }) {
  if (loading) return <p className="draft-history-center__loading">{t("正在读取版本历史…")}</p>;
  if (!items.length) return <EmptyState text={t("这篇文章尚无可用版本。下次保存前会自动创建保护版本。")} />;
  return <div className="draft-history-center__list" role="listbox" aria-label={t("文章版本")}>{items.map((item) => <button type="button" role="option" aria-selected={item.versionId === selectedId} className={item.versionId === selectedId ? "is-selected" : ""} key={item.versionId} disabled={busy} onClick={() => onSelect(item.versionId)}><strong>{t(versionReason(item.reason))}</strong><span>{formatTime(item.createdAtEpochSeconds, locale, t)} · {formatSize(item.byteSize)}</span></button>)}</div>;
}

function RecycleList({ items, selectedId, loading, busy, onSelect, locale, t }: { locale: UiLocale; t: UiTranslator; items: RecycledDraftSummary[]; selectedId: string | null; loading: boolean; busy: boolean; onSelect: (id: string) => void }) {
  if (loading) return <p className="draft-history-center__loading">{t("正在读取回收站…")}</p>;
  if (!items.length) return <EmptyState text={t("回收站为空。删除文章后会先安全地保留在这里。")} />;
  return <div className="draft-history-center__list" role="listbox" aria-label={t("回收文章")}>{items.map((item) => <button type="button" role="option" aria-selected={item.recycleId === selectedId} className={item.recycleId === selectedId ? "is-selected" : ""} key={item.recycleId} disabled={busy} onClick={() => onSelect(item.recycleId)}><strong>{item.relativePath}</strong><span>{formatTime(item.deletedAtEpochSeconds, locale, t)} · {formatSize(item.byteSize)}</span></button>)}</div>;
}

export default DraftHistoryCenter;
