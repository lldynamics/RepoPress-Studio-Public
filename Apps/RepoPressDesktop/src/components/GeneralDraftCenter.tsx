import { lazy, Suspense, useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import type { DocumentSnapshot, GeneralDraft, GeneralDraftSnapshot, GeneralDraftSummary, GeneralDraftTransferOperation, GeneralDraftTransferPlan, GeneralDraftTransferResult, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { ArticleStateContext } from "../contracts/articleState";
import { suggestedGeneralDraftPaths, withMarkdownExtension } from "../features/writing/generalDraftTransfer";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { useI18n, type MessageParameters, type UiTranslator } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { generalDraftMessages } from "../i18n/generalDraftMessages";
import "./GeneralDraftCenter.css";

const ArticleStatePanel = lazy(() => import("./ArticleStatePanel"));

export interface GeneralDraftCenterProps {
  open: boolean;
  onClose: () => void;
  gateway: RepositoryGateway;
  repository: RepositorySessionSnapshot | null;
  document: DocumentSnapshot | null;
  currentText: string;
  hasUnsavedChanges: boolean;
  onTransferApplied: (result: GeneralDraftTransferResult) => void | Promise<void>;
}

// Feedback records its origin so gateway text is never interpreted as a message key.
type Feedback = string | { raw: string } | { source: string; parameters: MessageParameters };
function feedbackText(value: Feedback, t: UiTranslator): string {
  return typeof value === "string" ? t(value) : "raw" in value ? value.raw : t(value.source, value.parameters);
}
function messageFrom(reason: unknown, fallback: string): Feedback {
  if (reason && typeof reason === "object" && "message" in reason && typeof reason.message === "string") return { raw: reason.message };
  return reason instanceof Error && reason.message ? { raw: reason.message } : fallback;
}

function formatTime(value: number, locale: UiLocale, unknownTime: string): string {
  const date = new Date(value * 1_000);
  return Number.isFinite(date.getTime()) ? date.toLocaleString(locale) : unknownTime;
}

function sortedNewest(entries: readonly GeneralDraftSummary[]) {
  return [...entries].sort((left, right) => right.updatedAtEpochSeconds - left.updatedAtEpochSeconds || left.draftId.localeCompare(right.draftId));
}

function operationLabel(operation: GeneralDraftTransferOperation): string {
  switch (operation) {
    case "copyCurrentToGeneral": return "复制当前文章到通用草稿";
    case "moveCurrentToGeneral": return "移动当前文章到通用草稿";
    case "copyGeneralToRepository": return "复制通用草稿到当前仓库";
    case "moveGeneralToRepository": return "移动通用草稿到当前仓库";
  }
}

function isMove(operation: GeneralDraftTransferOperation | null): boolean {
  return operation === "moveCurrentToGeneral" || operation === "moveGeneralToRepository";
}

export function GeneralDraftCenter({ open, onClose, gateway, repository, document, currentText, hasUnsavedChanges, onTransferApplied }: GeneralDraftCenterProps) {
  const { t, locale } = useI18n(generalDraftMessages);
  const root = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const listGeneration = useRef(0);
  const detailGeneration = useRef(0);
  const planContextRef = useRef("");
  const [drafts, setDrafts] = useState<GeneralDraftSummary[]>([]);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(() => new Set());
  const [previewId, setPreviewId] = useState<string | null>(null);
  const [draft, setDraft] = useState<GeneralDraft | null>(null);
  const [editText, setEditText] = useState("");
  const [targetPaths, setTargetPaths] = useState<Record<string, string>>({});
  const [plan, setPlan] = useState<GeneralDraftTransferPlan | null>(null);
  const [result, setResult] = useState<GeneralDraftTransferResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<Feedback>("");
  const [status, setStatus] = useState<Feedback>("");
  const articleStateContext = useMemo<ArticleStateContext | null>(() => draft
    ? { kind: "generalDraft", draftId: draft.draftId, writable: true } : null, [draft?.draftId]);

  const close = useCallback(() => { if (!busy) onClose(); }, [busy, onClose]);
  useDrawerFocus(open, root, close);

  const selectedEntries = useMemo(() => drafts.filter((entry) => selectedIds.has(entry.draftId)), [drafts, selectedIds]);
  const planContext = useMemo(() => JSON.stringify({
    sessionId: repository?.sessionId ?? null,
    repositoryRoot: repository?.rootPath ?? null,
    contentRoot: repository?.contentRoot ?? null,
    documentId: document?.documentId ?? null,
    baselineSha256: document?.baselineSha256 ?? null,
    revision: document?.revision ?? null,
    text: currentText,
    unsaved: hasUnsavedChanges,
    selected: [...selectedIds].sort(),
    paths: selectedEntries.map((entry) => [entry.draftId, targetPaths[entry.draftId] ?? ""]).sort(([left], [right]) => left.localeCompare(right)),
  }), [currentText, document?.baselineSha256, document?.documentId, document?.revision, hasUnsavedChanges, repository?.contentRoot, repository?.rootPath, repository?.sessionId, selectedEntries, selectedIds, targetPaths]);

  const loadDrafts = useCallback(async () => {
    const generation = ++listGeneration.current;
    setLoading(true); setError("");
    try {
      const snapshot: GeneralDraftSnapshot = await gateway.listGeneralDrafts();
      if (generation !== listGeneration.current) return;
      const entries = sortedNewest(snapshot.entries);
      setDrafts(entries);
      setSelectedIds((current) => new Set([...current].filter((id) => entries.some((entry) => entry.draftId === id))));
      setPreviewId((current) => entries.some((entry) => entry.draftId === current) ? current : entries[0]?.draftId ?? null);
      setTargetPaths((current) => {
        const suggestions = suggestedGeneralDraftPaths(entries, repository?.contentRoot ?? null);
        const next: Record<string, string> = {};
        for (const entry of entries) next[entry.draftId] = current[entry.draftId] ?? suggestions[entry.draftId];
        return next;
      });
      if (snapshot.truncated) setStatus({ source: "仅显示最近 {count} 篇通用草稿。", parameters: { count: entries.length } });
    } catch (reason) {
      if (generation === listGeneration.current) { setDrafts([]); setSelectedIds(new Set()); setPreviewId(null); setError(messageFrom(reason, "无法读取通用草稿库。")); }
    } finally { if (generation === listGeneration.current) setLoading(false); }
  }, [gateway, repository?.contentRoot]);

  useEffect(() => {
    listGeneration.current += 1; detailGeneration.current += 1;
    setDrafts([]); setSelectedIds(new Set()); setPreviewId(null); setDraft(null); setEditText(""); setTargetPaths({});
    setPlan(null); planContextRef.current = ""; setResult(null); setError(""); setStatus("");
    if (open) void loadDrafts();
  }, [gateway, loadDrafts, open]);

  useEffect(() => {
    if (!open || !previewId) { setDraft(null); setEditText(""); return; }
    const generation = ++detailGeneration.current;
    setDraft(null); setEditText(""); setError("");
    void gateway.getGeneralDraft(previewId).then((next) => {
      if (generation !== detailGeneration.current) return;
      setDraft(next); setEditText(next.text);
    }).catch((reason: unknown) => { if (generation === detailGeneration.current) setError(messageFrom(reason, "无法读取通用草稿。")); });
  }, [gateway, open, previewId]);

  // A plan binds the selected drafts, paths, saved editor identity, and target repository.
  // Any visible-context change must make its one-shot plan ineligible for execution.
  useEffect(() => {
    if (plan && planContextRef.current !== planContext) {
      setPlan(null); planContextRef.current = "";
      setStatus("计划已因文章、选择、路径或目标仓库变化而失效，请重新生成。 ");
    }
  }, [plan, planContext]);

  const currentTransferDisabled = busy || !repository || !document || !document.writable || hasUnsavedChanges;
  const libraryTransferDisabled = busy || !repository || selectedEntries.length === 0;

  function toggleSelected(draftId: string) {
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(draftId)) next.delete(draftId); else next.add(draftId);
      return next;
    });
  }

  function updateTargetPath(draftId: string, value: string) {
    setTargetPaths((current) => ({ ...current, [draftId]: value }));
  }

  async function saveDraft() {
    if (!draft || busy || editText === draft.text) return;
    setBusy(true); setError(""); setStatus("正在保存通用草稿…");
    try {
      const saved = await gateway.saveGeneralDraft({ draftId: draft.draftId, text: editText, expectedRevision: draft.revision, expectedSha256: draft.contentSha256 });
      setDraft(saved); setEditText(saved.text); setStatus("通用草稿已保存。");
      await loadDrafts();
    } catch (reason) { setError(messageFrom(reason, "保存通用草稿失败；内容没有被覆盖。")); setStatus(""); }
    finally { setBusy(false); }
  }

  async function makePlan(operation: GeneralDraftTransferOperation) {
    if (!repository || busy) return;
    if ((operation === "copyCurrentToGeneral" || operation === "moveCurrentToGeneral") && (!document || !document.writable || hasUnsavedChanges)) return;
    if ((operation === "copyGeneralToRepository" || operation === "moveGeneralToRepository") && !selectedEntries.length) return;
    const targetItems = (operation === "copyGeneralToRepository" || operation === "moveGeneralToRepository")
      ? selectedEntries.map((entry) => ({ draftId: entry.draftId, relativePath: withMarkdownExtension(targetPaths[entry.draftId] ?? "") }))
      : undefined;
    setBusy(true); setError(""); setStatus("正在核对转移计划…"); setPlan(null); planContextRef.current = "";
    try {
      const next = await gateway.planGeneralDraftTransfer({
        sessionId: repository.sessionId,
        operation,
        documentId: document?.documentId ?? null,
        expectedSha256: document?.baselineSha256 ?? null,
        targetItems,
      });
      setPlan(next); planContextRef.current = planContext;
      setStatus(next.canApply ? "计划已生成，请核对后确认执行。" : "计划包含冲突，不能执行。请调整后重新生成。");
    } catch (reason) { setError(messageFrom(reason, "无法生成转移计划。")); setStatus(""); }
    finally { setBusy(false); }
  }

  async function executePlan() {
    if (!repository || !plan || busy || !plan.canApply || planContextRef.current !== planContext) {
      if (plan && planContextRef.current !== planContext) { setPlan(null); setStatus("计划已失效，请重新生成。 "); }
      return;
    }
    if (isMove(plan.operation) && !window.confirm(t("这是移动操作：源内容会被移除，随后可使用本弹层的一次性撤销。确认继续吗？"))) return;
    setBusy(true); setError(""); setStatus("正在执行已核对的转移…");
    try {
      const next = await gateway.executeGeneralDraftTransfer({ sessionId: repository.sessionId, planId: plan.planId });
      setResult(next); setPlan(null); planContextRef.current = ""; setStatus(next.summary ? { raw: next.summary } : "转移已完成，可在本弹层中撤销一次。");
      try { await onTransferApplied(next); } catch { setError("转移已完成，但工作区刷新失败。请重新打开受影响的文章。 "); }
      await loadDrafts();
    } catch (reason) { setError(messageFrom(reason, "转移未完成；已保留当前界面。")); setStatus(""); }
    finally { setBusy(false); }
  }

  async function undoTransfer() {
    if (!repository || !result || busy) return;
    if (!window.confirm(t("撤销上一项转移？如果源或目标已被编辑，撤销会安全地拒绝覆盖。"))) return;
    setBusy(true); setError(""); setStatus("正在撤销转移…");
    try {
      const undone = await gateway.undoGeneralDraftTransfer({ sessionId: repository.sessionId, undoId: result.undoId });
      const callbackResult: GeneralDraftTransferResult = {
        operation: result.operation,
        affectedGeneralDraftIds: undone.restoredGeneralDraftIds,
        affectedRelativePaths: undone.restoredRelativePaths,
        undoId: "",
        summary: undone.summary,
      };
      setResult(null); setStatus(undone.summary ? { raw: undone.summary } : "已撤销上一项转移。");
      try { await onTransferApplied(callbackResult); } catch { setError("撤销已完成，但工作区刷新失败。请重新打开受影响的文章。 "); }
      await loadDrafts();
    } catch (reason) { setError(messageFrom(reason, "撤销失败；为了避免覆盖新内容，未修改当前草稿。")); setStatus(""); }
    finally { setBusy(false); }
  }

  if (!open) return null;

  return <div ref={root} className="general-draft-scrim" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) close(); }}>
    <section className="general-draft-center" role="dialog" aria-modal="true" aria-labelledby={titleId} aria-busy={loading || busy} tabIndex={-1}>
      <header className="general-draft-center__header">
        <div><h2 id={titleId}>{t("通用草稿库")}</h2><p>{t("跨站点通过通用草稿中转，不代表自动搬附件或改写 front matter。")}</p></div>
        <button type="button" className="general-draft-center__close" onClick={close} disabled={busy} aria-label={t("关闭通用草稿库")}>×</button>
      </header>
      <div className="general-draft-center__body">
        <section className="general-draft-center__current" aria-labelledby="general-draft-current-title">
          <div><h3 id="general-draft-current-title">{t("当前文章")}</h3><p>{document ? document.relativePath : t("未打开文章")}</p></div>
          <div className="general-draft-center__actions">
            <button type="button" onClick={() => void makePlan("copyCurrentToGeneral")} disabled={currentTransferDisabled}>{t("复制到通用草稿")}</button>
            <button type="button" className="danger" onClick={() => void makePlan("moveCurrentToGeneral")} disabled={currentTransferDisabled}>{t("移动到通用草稿")}</button>
          </div>
          {!repository ? <p className="general-draft-center__hint">{t("先切换目标仓库后，才能从当前文章创建通用草稿。")}</p> : !document ? <p className="general-draft-center__hint">{t("先打开一篇可写文章。")}</p> : !document.writable ? <p className="general-draft-center__hint">{t("当前文章不可写：{reason}", { reason: document.readOnlyReason ?? t("请切换到可写文章。") })}</p> : hasUnsavedChanges ? <p className="general-draft-center__hint">{t("必须先保存当前文章，才能安全地复制或移动到通用草稿。")}</p> : null}
        </section>

        <section className="general-draft-center__library" aria-labelledby="general-draft-library-title">
          <div className="general-draft-center__library-heading"><div><h3 id="general-draft-library-title">{t("通用草稿")}</h3><p>{loading ? t("正在读取…") : t("{count} 篇可用草稿", { count: drafts.length })}</p></div><button type="button" onClick={() => void loadDrafts()} disabled={busy || loading}>{t("刷新")}</button></div>
          {loading ? <p className="general-draft-center__empty">{t("正在读取通用草稿库…")}</p> : !drafts.length ? <p className="general-draft-center__empty">{t("通用草稿库为空。可先将已保存的当前文章复制或移动到这里。")}</p> : <div className="general-draft-center__grid">
            <div className="general-draft-center__list" role="list" aria-label={t("通用草稿列表")}>
              {drafts.map((entry) => <article className={previewId === entry.draftId ? "is-selected" : ""} key={entry.draftId} role="listitem">
                <label><input type="checkbox" checked={selectedIds.has(entry.draftId)} disabled={busy} onChange={() => toggleSelected(entry.draftId)} aria-label={t("选择 {title}", { title: entry.title })} /><span /></label>
                <button type="button" onClick={() => setPreviewId(entry.draftId)} disabled={busy} aria-current={previewId === entry.draftId ? "true" : undefined}><strong>{entry.title}</strong><span>{formatTime(entry.updatedAtEpochSeconds, locale, t("时间未知"))} · r{entry.revision}</span></button>
              </article>)}
            </div>
            <article className="general-draft-center__detail">
              {draft ? <><h4>{draft.title}</h4><p>{draft.sourceRepositoryName ? t("源：{source}", { source: `${draft.sourceRepositoryName}${draft.sourceRelativePath ? ` / ${draft.sourceRelativePath}` : ""}` }) : t("不绑定任何仓库")}</p>{articleStateContext && <Suspense fallback={<p role="status">{t("文章状态")}</p>}><ArticleStatePanel compact active={open}
                value={editText} context={articleStateContext} contextKey={JSON.stringify([draft.draftId, draft.revision, draft.contentSha256])} /></Suspense>}<label><span>{t("草稿正文")}</span><textarea value={editText} onChange={(event) => setEditText(event.target.value)} disabled={busy} spellCheck /></label><button type="button" className="primary" onClick={() => void saveDraft()} disabled={busy || editText === draft.text}>{t("保存通用草稿")}</button></> : <p className="general-draft-center__empty">{t("选择一篇草稿以预览或编辑。")}</p>}
            </article>
          </div>}
        </section>

        <section className="general-draft-center__destination" aria-labelledby="general-draft-destination-title">
          <div><h3 id="general-draft-destination-title">{t("导入到当前仓库")}</h3><p>{repository ? t("目标：{name}", { name: repository.displayName }) : t("尚未选择目标仓库")}</p></div>
          {!repository ? <p className="general-draft-center__hint">{t("先切换目标仓库。")}</p> : <>
            <div className="general-draft-center__actions"><button type="button" onClick={() => void makePlan("copyGeneralToRepository")} disabled={libraryTransferDisabled}>{t("复制所选草稿")}</button><button type="button" className="danger" onClick={() => void makePlan("moveGeneralToRepository")} disabled={libraryTransferDisabled}>{t("移动所选草稿")}</button></div>
            {selectedEntries.length > 0 && <div className="general-draft-center__paths">{selectedEntries.map((entry) => <label key={entry.draftId}><span>{entry.title}</span><input value={targetPaths[entry.draftId] ?? ""} disabled={busy} spellCheck={false} autoComplete="off" onChange={(event) => updateTargetPath(entry.draftId, event.target.value)} aria-label={t("{title} 的目标 Markdown 路径", { title: entry.title })} /></label>)}</div>}
            {!selectedEntries.length && <p className="general-draft-center__hint">{t("勾选一篇或多篇通用草稿，再设置各自的仓库内 Markdown 路径。")}</p>}
          </>}
        </section>

        {plan && <TransferPlanView plan={plan} onCancel={() => { setPlan(null); planContextRef.current = ""; setStatus("已取消待执行计划。 "); }} onExecute={() => void executePlan()} busy={busy} />}
        {result && <section className="general-draft-center__undo" aria-label={t("已完成的转移")}><p>{result.summary || t("已完成：{operation}。", { operation: t(operationLabel(result.operation)) })}</p><button type="button" onClick={() => void undoTransfer()} disabled={busy}>{t("撤销上一项转移")}</button></section>}
        {feedbackText(error, t) && <p className="general-draft-center__error" role="alert">{feedbackText(error, t)}</p>}
        <p className="general-draft-center__status" aria-live="polite">{feedbackText(status, t)}</p>
      </div>
      <footer className="general-draft-center__footer"><span>{t("所有转移都先生成计划，并在执行时再次验证。")}</span><button type="button" onClick={close} disabled={busy}>{t("关闭")}</button></footer>
    </section>
  </div>;
}

function TransferPlanView({ plan, busy, onCancel, onExecute }: { plan: GeneralDraftTransferPlan; busy: boolean; onCancel: () => void; onExecute: () => void }) {
  const { t } = useI18n(generalDraftMessages);
  return <section className="general-draft-center__plan" aria-labelledby="general-draft-plan-title">
    <h3 id="general-draft-plan-title">{t("核对转移计划：{operation}", { operation: t(operationLabel(plan.operation)) })}</h3>
    {isMove(plan.operation) && <p className="general-draft-center__move-notice">{t("移动会移除源内容；执行后可撤销一次，但若任一端已编辑，撤销会拒绝覆盖。")}</p>}
    <ul>{plan.items.map((item, index) => <li key={`${item.draftId ?? "current"}-${index}`}><strong>{item.title}</strong><span>{item.sourceLabel}{item.sourceRelativePath ? ` / ${item.sourceRelativePath}` : ""} → {item.targetLabel}{item.targetRelativePath ? ` / ${item.targetRelativePath}` : ""}</span>{item.conflicts.map((conflict) => <em key={conflict.id}>{conflict.message}</em>)}</li>)}</ul>
    {plan.warnings.length > 0 && <div className="general-draft-center__warnings"><strong>{t("提示")}</strong>{plan.warnings.map((warning) => <p key={warning}>{warning}</p>)}</div>}
    {plan.conflicts.length > 0 && <div className="general-draft-center__conflicts" role="alert"><strong>{t("无法执行")}</strong>{plan.conflicts.map((conflict) => <p key={conflict.id}>{conflict.message}</p>)}</div>}
    <div className="general-draft-center__plan-actions"><button type="button" onClick={onCancel} disabled={busy}>{t("取消计划")}</button><button type="button" className="primary" onClick={onExecute} disabled={busy || !plan.canApply}>{t("确认执行")}</button></div>
  </section>;
}

export default GeneralDraftCenter;
