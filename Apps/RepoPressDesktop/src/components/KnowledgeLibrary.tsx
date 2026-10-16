import { useEffect, useRef, useState } from "react";
import type {
  BrowserCaptureStatus,
  KnowledgeExportPlan,
  KnowledgeArchiveExportPlan,
  KnowledgeImportRequest,
  KnowledgeItem,
  KnowledgeItemSummary,
  KnowledgeLibraryStatus,
  KnowledgeFolder,
  KnowledgeRevisionSummary,
  KnowledgeSearchSnapshot,
  RepositoryGateway,
  RepositorySessionSnapshot,
} from "../contracts/repository";
import {
  clampProgress,
  defaultExportPath,
  defaultArchivePath,
  isExportPlanExpired,
  normalizeKnowledgeItem,
  filterKnowledgeItems,
  safeSourceUrl,
} from "../features/knowledge/knowledgeLibrary";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { useI18n, type UiTranslator } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import { knowledgeMessages } from "../i18n/knowledgeMessages";

type BusyAction = "load" | "open" | "import" | "search" | "progress" | "delete" | "export" | "archive" | "rotate" | "folder" | "move" | "revision" | "remote-permission" | null;
interface KnowledgeUiMessage extends UiMessage {
  byteSize?: number;
  maskedError?: readonly (string | null)[];
}

export interface KnowledgeLibraryProps {
  open: boolean;
  onClose: () => void;
  gateway: RepositoryGateway;
  repository: RepositorySessionSnapshot | null;
  targetItemId?: string | null;
  targetRequestKey?: number;
}

const EMPTY_IMPORT: KnowledgeImportRequest = {
  sourceKind: "text",
  title: "",
  sourceName: "",
  sourceUrl: null,
  text: "",
  allowsLocalSemanticIndex: false,
  allowsRemoteAiUse: false,
};

export function KnowledgeLibrary({ open, onClose, gateway, repository, targetItemId = null, targetRequestKey = 0 }: KnowledgeLibraryProps) {
  const { locale, t } = useI18n(knowledgeMessages);
  const [status, setStatus] = useState<KnowledgeLibraryStatus | null>(null);
  const [items, setItems] = useState<KnowledgeItemSummary[]>([]);
  const [selected, setSelected] = useState<KnowledgeItem | null>(null);
  const [progressDraft, setProgressDraft] = useState<number | null>(null);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<KnowledgeSearchSnapshot | null>(null);
  const [browser, setBrowser] = useState<BrowserCaptureStatus | null>(null);
  const [busy, setBusy] = useState<BusyAction>(null);
  const [message, setMessage] = useState<KnowledgeUiMessage | null>(null);
  const [draft, setDraft] = useState<KnowledgeImportRequest>(EMPTY_IMPORT);
  const [path, setPath] = useState("");
  const [plan, setPlan] = useState<KnowledgeExportPlan | null>(null);
  const [archivePath, setArchivePath] = useState("");
  const [archivePlan, setArchivePlan] = useState<KnowledgeArchiveExportPlan | null>(null);
  const [folders, setFolders] = useState<KnowledgeFolder[]>([]);
  const [folderFilter, setFolderFilter] = useState<string | null | "all">("all");
  const [newFolder, setNewFolder] = useState("");
  const [revisions, setRevisions] = useState<KnowledgeRevisionSummary[]>([]);
  const [viewedRevision, setViewedRevision] = useState<number | null>(null);
  const [revisionText, setRevisionText] = useState<string | null>(null);
  const generation = useRef(0);
  const drawer = useRef<HTMLDivElement>(null);
  useDrawerFocus(open, drawer, onClose);

  useEffect(() => {
    if (!open) return;
    const current = ++generation.current;
    setBusy("load");
    setMessage(null);
    setSelected(null);
    setProgressDraft(null);
    setResults(null);
    setPath("");
    setPlan(null);
    setArchivePlan(null);
    void Promise.all([
      gateway.knowledgeLibraryStatus(),
      gateway.listKnowledgeItems(100),
      gateway.browserCaptureStatus(),
      gateway.listKnowledgeFolders(),
    ])
      .then(([nextStatus, list, nextBrowser, folderSnapshot]) => {
        if (current !== generation.current) return;
        setStatus(nextStatus);
        setItems(list.items.map((item) => normalizeKnowledgeItem(item)));
        setBrowser(nextBrowser);
        setFolders(folderSnapshot.folders);
        if (targetItemId) {
          // Extension receipts can point to an item outside the bounded list window.
          // `choose` only needs the stable ID and fetches the authoritative detail itself.
          setFolderFilter("all");
          return choose({ itemId: targetItemId } as KnowledgeItemSummary);
        }
      })
      .catch((error: unknown) => {
        if (current === generation.current) setMessage(errorMessage("无法加载资料库：{message}", error));
      })
      .finally(() => {
        if (current === generation.current) setBusy(null);
      });
    return () => {
      generation.current += 1;
    };
  }, [gateway, open, targetItemId, targetRequestKey]);

  useEffect(() => {
    setPlan(null);
    setArchivePlan(null);
  }, [path, archivePath, repository?.sessionId, selected?.itemId]);

  async function refresh(current = generation.current) {
    const [nextStatus, list] = await Promise.all([
      gateway.knowledgeLibraryStatus(),
      gateway.listKnowledgeItems(100),
    ]);
    if (current !== generation.current) return;
    setStatus(nextStatus);
    setItems(list.items.map((item) => normalizeKnowledgeItem(item)));
  }

  async function choose(item: KnowledgeItemSummary) {
    const current = generation.current;
    setBusy("open");
    setMessage(null);
    try {
      const [rawDetail, revisionSnapshot] = await Promise.all([
        gateway.getKnowledgeItem(item.itemId),
        gateway.listKnowledgeRevisions(item.itemId).catch(() => ({ itemId: item.itemId, revisions: [] })),
      ]);
      const detail = normalizeKnowledgeItem(rawDetail);
      if (current !== generation.current) return;
      setSelected(detail);
      setViewedRevision(null); setRevisionText(null);
      setRevisions(revisionSnapshot.revisions);
      setProgressDraft(detail.readingProgressPercent);
      setPath(defaultExportPath(detail));
      setArchivePath(detail.archive ? defaultArchivePath(detail, detail.archive.format) : "");
    } catch (error) {
      if (current === generation.current) setMessage(errorMessage("无法打开资料：{message}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function createFolder() {
    const name = newFolder.trim(); if (!name || busy) return;
    setBusy("folder"); setMessage(null);
    try { const folder = await gateway.createKnowledgeFolder(name); setFolders((current) => [...current, folder]); setNewFolder(""); setMessage({ source: "已创建分类“{name}”。", parameters: { name: folder.name } }); }
    catch (error) { setMessage(errorMessage("创建分类失败：{message}", error)); } finally { setBusy(null); }
  }
  async function moveSelected(folderId: string | null) {
    if (!selected || busy || selected.folderId === folderId) return;
    setBusy("move"); setMessage(null);
    try { const summary = await gateway.moveKnowledgeItem(selected.itemId, folderId); setSelected((item) => item ? { ...item, ...summary } : item); setItems((current) => current.map((item) => item.itemId === summary.itemId ? summary : item)); setMessage({ source: "已更新资料分类。" }); }
    catch (error) { setMessage(errorMessage("移动分类失败：{message}", error)); } finally { setBusy(null); }
  }
  async function openRevision(number: number) {
    if (!selected || busy) return;
    const current = generation.current;
    setBusy("revision"); setMessage(null);
    try {
      const revision = await gateway.getKnowledgeRevision(selected.itemId, number);
      if (current !== generation.current) return;
      setViewedRevision(number); setRevisionText(revision.text);
    }
    catch (error) { if (current === generation.current) setMessage(errorMessage("无法读取历史版本：{message}", error)); }
    finally { if (current === generation.current) setBusy(null); }
  }

  async function importItem(event: React.FormEvent) {
    event.preventDefault();
    if (status?.ready !== true || busy) return;
    const title = draft.title.trim();
    const sourceName = draft.sourceName.trim();
    const text = draft.text.trim();
    const sourceUrl = draft.sourceKind === "web" ? safeSourceUrl(draft.sourceUrl) : null;
    if (!title || !sourceName || !text) {
      setMessage({ source: "请填写标题、来源名称和正文。" });
      return;
    }
    if (draft.sourceKind === "web" && !sourceUrl) {
      setMessage({ source: "网页资料需要填写不含账号密码的 HTTP 或 HTTPS 来源链接。" });
      return;
    }
    const current = generation.current;
    setBusy("import");
    setMessage(null);
    try {
      const result = await gateway.importKnowledgeText({ ...draft, title, sourceName, sourceUrl, text });
      if (current !== generation.current) return;
      setMessage({ source: result.deduplicated ? "资料已存在，未重复保存。" : "资料已导入本地资料库。" });
      setDraft({ ...EMPTY_IMPORT, allowsLocalSemanticIndex: draft.allowsLocalSemanticIndex });
      await refresh(current);
    } catch (error) {
      if (current === generation.current) setMessage(errorMessage("导入失败：{message}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function setRemoteAiPermission(allowsRemoteAiUse: boolean) {
    if (!selected || busy) return;
    const current = generation.current;
    setBusy("remote-permission"); setMessage(null);
    try {
      const summary = await gateway.setKnowledgeRemoteAiPermission({ itemId: selected.itemId, allowsRemoteAiUse });
      if (current !== generation.current) return;
      setSelected((item) => item?.itemId === summary.itemId ? { ...item, ...summary } : item);
      setItems((currentItems) => currentItems.map((item) => item.itemId === summary.itemId ? summary : item));
      setMessage({ source: allowsRemoteAiUse ? "已允许此资料在确认后发送给远程 AI。" : "已撤销此资料的远程 AI 发送许可；后续对话不会再选用它。" });
    } catch (error) {
      if (current === generation.current) setMessage(errorMessage("更新远程 AI 许可失败：{message}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function saveProgress(value: number) {
    if (!selected || busy) return;
    const current = generation.current;
    const progressPercent = clampProgress(value);
    setBusy("progress");
    try {
      const summary = await gateway.updateKnowledgeProgress({ itemId: selected.itemId, progressPercent });
      if (current !== generation.current) return;
      setSelected((item) => item?.itemId === summary.itemId ? { ...item, ...summary } : item);
      setProgressDraft(summary.readingProgressPercent);
      setItems((currentItems) => currentItems.map((item) => item.itemId === summary.itemId ? summary : item));
    } catch (error) {
      if (current === generation.current) {
        setProgressDraft(selected.readingProgressPercent);
        setMessage(errorMessage("进度保存失败：{message}", error));
      }
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function search() {
    if (!query.trim()) {
      setResults(null);
      return;
    }
    const current = generation.current;
    setBusy("search");
    setMessage(null);
    try {
      const snapshot = await gateway.searchKnowledgeItems(query.trim(), 30);
      if (current === generation.current) setResults(snapshot);
    } catch (error) {
      if (current === generation.current) setMessage(errorMessage("搜索失败：{message}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function remove() {
    if (!selected || busy || !window.confirm(t("删除“{title}”？此操作不可撤销。", { title: selected.title }))) return;
    const current = generation.current;
    setBusy("delete");
    try {
      const nextStatus = await gateway.deleteKnowledgeItem(selected.itemId);
      if (current !== generation.current) return;
      setStatus(nextStatus);
      setSelected(null);
      setProgressDraft(null);
      setResults(null);
      await refresh(current);
      setMessage(nextStatus.warning ? { source: "已删除资料；{warning}", parameters: { warning: nextStatus.warning } } : { source: "已删除资料。" });
    } catch (error) {
      if (current === generation.current) setMessage(errorMessage("删除失败：{message}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function exportItem() {
    if (!selected || !repository || busy) return;
    const relativePath = path.trim() || defaultExportPath(selected);
    const current = generation.current;
    setBusy("export");
    setMessage(null);
    try {
      if (!plan) {
        const nextPlan = await gateway.planKnowledgeExport({ sessionId: repository.sessionId, itemId: selected.itemId, relativePath });
        if (current === generation.current) {
          setPath(relativePath);
          setPlan(nextPlan);
        }
        return;
      }
      if (isExportPlanExpired(plan)) {
        setPlan(null);
        setMessage({ source: "导出计划已过期，请重新生成。" });
        return;
      }
      const result = await gateway.executeKnowledgeExport(repository.sessionId, plan.planId);
      if (current !== generation.current) return;
      setPlan(null);
      setMessage({ source: "已写入 {path}（{size}）；尚未暂存或提交。", parameters: { path: result.relativePath }, byteSize: result.byteSize });
    } catch (error) {
      if (current === generation.current) setMessage(errorMessage("导出失败：{message}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  async function exportArchive() {
    if (!selected?.archive || !repository || busy) return;
    const relativePath = archivePath.trim() || defaultArchivePath(selected, selected.archive.format);
    const current = generation.current;
    setBusy("archive");
    setMessage(null);
    try {
      if (!archivePlan) {
        const nextPlan = await gateway.planKnowledgeArchiveExport({ sessionId: repository.sessionId, itemId: selected.itemId, relativePath });
        if (current === generation.current) { setArchivePath(relativePath); setArchivePlan(nextPlan); }
        return;
      }
      if (isExportPlanExpired(archivePlan)) { setArchivePlan(null); setMessage({ source: "离线归档导出计划已过期，请重新生成。" }); return; }
      const result = await gateway.executeKnowledgeArchiveExport({ sessionId: repository.sessionId, planId: archivePlan.planId });
      if (current !== generation.current) return;
      setArchivePlan(null);
      setMessage({ source: "已写入离线归档 {path}（{size}）；尚未暂存或提交。", parameters: { path: result.relativePath }, byteSize: result.byteSize });
    } catch (error) { if (current === generation.current) setMessage(errorMessage("离线归档导出失败：{message}", error)); }
    finally { if (current === generation.current) setBusy(null); }
  }

  async function copyToken() {
    if (!browser?.connectionToken) return;
    try {
      await navigator.clipboard.writeText(browser.connectionToken);
      setMessage({ source: "配对令牌已复制；请只粘贴到 RepoPress 浏览器扩展。" });
    } catch (error) {
      setMessage(errorMessage("无法复制配对令牌：{message}", error));
    }
  }

  async function rotate() {
    if (busy || !window.confirm(t("确定轮换浏览器令牌？扩展中保存的旧令牌将立即失效。"))) return;
    const current = generation.current;
    setBusy("rotate");
    setMessage(null);
    try {
      const next = await gateway.rotateBrowserCaptureToken();
      if (current === generation.current) {
        setBrowser(next);
        setMessage({ source: "已生成新的浏览器配对令牌。" });
      }
    } catch (error) {
      if (current === generation.current) setMessage(errorMessage("令牌轮换失败：{message}", error));
    } finally {
      if (current === generation.current) setBusy(null);
    }
  }

  if (!open) return null;
  const displayed = results ? results.results.filter((result) => filterKnowledgeItems([normalizeKnowledgeItem(result.item)], folderFilter).length > 0) : filterKnowledgeItems(items, folderFilter).map((item) => ({ item, score: 0, lexicalScore: 0, semanticScore: 0, snippet: "", reason: "" }));
  const sourceUrl = safeSourceUrl(selected?.sourceUrl);
  const exportPath = selected ? path || defaultExportPath(selected) : "";
  const unavailable = status !== null && !status.ready;
  const historicalRevisions = selected
    ? revisions.filter((revision) => revision.revisionNumber !== selected.revisionNumber)
    : [];

  return (
    <div ref={drawer} className="knowledge-scrim" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <aside className="knowledge-library" role="dialog" aria-modal="true" aria-labelledby="knowledge-title">
        <header className="knowledge-header">
          <div><h1 id="knowledge-title">{t("资料库")}</h1><p>{t("资料保存在本机；只有明确确认后才会导出到仓库。")}</p></div>
          <button type="button" className="publish-close" onClick={onClose} aria-label={t("关闭资料库")}>×</button>
        </header>
        <div className="knowledge-content">
          <p className={unavailable ? "tool-warning" : "tool-state"}>{status?.summary ?? t("正在加载…")}</p>
          {status?.warning && <p className="tool-warning">{status.warning}</p>}
          {message && <p className="tool-state" role="status">{renderKnowledgeMessage(message, locale, t)}</p>}

          <section className="knowledge-section">
            <h2>{t("资料检索")}</h2>
            <div className="tool-search">
              <label htmlFor="knowledge-query">{t("语义搜索")}</label>
              <input id="knowledge-query" value={query} onChange={(event) => setQuery(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") void search(); }} placeholder={t("搜索标题、来源和正文")} disabled={unavailable || busy !== null} />
              <button type="button" onClick={() => void search()} disabled={unavailable || busy !== null}>{t("搜索")}</button>
            </div>
            <div className="knowledge-filter"><label htmlFor="knowledge-folder-filter">{t("分类筛选")}</label><select id="knowledge-folder-filter" value={folderFilter === "all" ? "all" : folderFilter ?? "uncategorized"} onChange={(event) => setFolderFilter(event.target.value === "all" ? "all" : event.target.value === "uncategorized" ? null : event.target.value)} disabled={busy !== null}><option value="all">{t("全部")}</option><option value="uncategorized">{t("未分类")}</option>{folders.map((folder) => <option key={folder.folderId} value={folder.folderId}>{folder.name}</option>)}</select><input aria-label={t("新分类名称")} value={newFolder} onChange={(event) => setNewFolder(event.target.value)} placeholder={t("新建分类")} disabled={busy !== null} /><button type="button" onClick={() => void createFolder()} disabled={!newFolder.trim() || busy !== null}>{t("创建分类")}</button></div>
            <div className="knowledge-results">
              {displayed.map((result) => <button type="button" className="knowledge-item" key={result.item.itemId} onClick={() => void choose(result.item)} disabled={busy !== null}>
                <strong>{result.item.title}</strong>
                <small>{result.item.sourceName} · {sourceKindLabel(result.item.sourceKind, t)} · {t("阅读 {percent}%", { percent: formatNumber(result.item.readingProgressPercent, locale) })}</small>
                {result.snippet && <span>{result.snippet}</span>}
              </button>)}
            </div>
            {!results && items.length === 0 && <p className="tool-muted">{t("资料库为空。导入只会在点击确认后发生。")}</p>}
            {results && results.results.length === 0 && <p className="tool-muted">{t("没有找到匹配资料。")}</p>}
          </section>

          <section className="knowledge-section">
            <h2>{t("显式导入文字")}</h2>
            <form onSubmit={(event) => void importItem(event)} className="knowledge-form">
              <label htmlFor="knowledge-source-kind">{t("来源类型")}
                <select id="knowledge-source-kind" value={draft.sourceKind} onChange={(event) => setDraft({ ...draft, sourceKind: event.target.value as "text" | "web", sourceUrl: event.target.value === "web" ? draft.sourceUrl : null })} disabled={unavailable || busy !== null}>
                  <option value="text">{t("粘贴文字")}</option><option value="web">{t("网页内容")}</option>
                </select>
              </label>
              <label htmlFor="knowledge-title-input">{t("标题")}<input id="knowledge-title-input" required value={draft.title} onChange={(event) => setDraft({ ...draft, title: event.target.value })} disabled={unavailable || busy !== null} /></label>
              <label htmlFor="knowledge-source-name">{t("来源名称")}<input id="knowledge-source-name" required value={draft.sourceName} onChange={(event) => setDraft({ ...draft, sourceName: event.target.value })} disabled={unavailable || busy !== null} /></label>
              {draft.sourceKind === "web" && <label htmlFor="knowledge-source-url">{t("来源链接")}<input id="knowledge-source-url" required value={draft.sourceUrl ?? ""} onChange={(event) => setDraft({ ...draft, sourceUrl: event.target.value || null })} placeholder="https://…" disabled={unavailable || busy !== null} /></label>}
              <label htmlFor="knowledge-text">{t("正文")}<textarea id="knowledge-text" required value={draft.text} onChange={(event) => setDraft({ ...draft, text: event.target.value })} disabled={unavailable || busy !== null} /></label>
              <label className="knowledge-check"><input type="checkbox" checked={draft.allowsLocalSemanticIndex} onChange={(event) => setDraft({ ...draft, allowsLocalSemanticIndex: event.target.checked })} disabled={unavailable || busy !== null} />{t("允许此资料参与本机语义索引")}</label>
              <label className="knowledge-check"><input type="checkbox" checked={draft.allowsRemoteAiUse === true} onChange={(event) => setDraft({ ...draft, allowsRemoteAiUse: event.target.checked })} disabled={unavailable || busy !== null} />{t("允许此资料在每次确认后发送给远程 AI")}</label>
              <p className="tool-muted">{t("默认关闭。仅在 AI 对话中手动勾选该资料并确认发送时，资料正文才会发送给外部服务；可随时在详情中撤销。")}</p>
              <button disabled={unavailable || busy !== null} type="submit">{busy === "import" ? t("正在导入…") : t("导入资料库")}</button>
            </form>
          </section>

          {selected && <section className="knowledge-section">
            <h2>{t("资料详情")}</h2>
            <dl className="tool-details"><dt>{t("标题")}</dt><dd>{selected.title}</dd><dt>{t("来源")}</dt><dd>{selected.sourceName}</dd><dt>{t("大小")}</dt><dd>{formatBytes(selected.byteSize, locale, t)}</dd><dt>{t("导入时间")}</dt><dd>{formatEpochSeconds(selected.createdAtEpochSeconds, locale, t)}</dd><dt>{t("当前修订")}</dt><dd>{t("版本 {revision} / {count}", { revision: formatNumber(selected.revisionNumber ?? 1, locale), count: formatNumber(selected.revisionCount ?? 1, locale) })}</dd><dt>{t("分类")}</dt><dd><select aria-label={t("资料分类")} value={selected.folderId ?? ""} onChange={(event) => void moveSelected(event.target.value || null)} disabled={busy !== null}><option value="">{t("未分类")}</option>{folders.map((folder) => <option key={folder.folderId} value={folder.folderId}>{folder.name}</option>)}</select></dd></dl>
            <div className="knowledge-remote-ai">
              <label className="knowledge-check"><input type="checkbox" checked={selected.allowsRemoteAiUse === true} onChange={(event) => void setRemoteAiPermission(event.target.checked)} disabled={busy !== null} />{t("允许发送给远程 AI")}</label>
              <p className="tool-muted">{t("默认关闭。开启并不自动发送；仍需在 AI 对话里逐条勾选并查看发送计划。关闭会撤销后续发送许可，已发送的内容无法从服务方撤回。")}</p>
            </div>
            {viewedRevision != null ? <><p className="tool-warning">{t("历史版本：版本 {revision}（只读预览）", { revision: formatNumber(viewedRevision, locale) })}</p><button type="button" onClick={() => { setViewedRevision(null); setRevisionText(null); }}>{t("返回当前版本")}</button><pre className="tool-text-preview">{revisionText == null ? t("正在加载历史版本…") : <>{revisionText.slice(0, 8_000)}{revisionText.length > 8_000 ? `\n\n…（${t("预览已截断")}）` : ""}</>}</pre></> : <pre className="tool-text-preview">{selected.text.slice(0, 8_000)}{selected.text.length > 8_000 ? `\n\n…（${t("预览已截断")}）` : ""}</pre>}
            {historicalRevisions.length > 0 && <div className="knowledge-revisions"><strong>{t("版本历史")}</strong>{historicalRevisions.map((revision) => <button type="button" key={revision.revisionNumber} onClick={() => void openRevision(revision.revisionNumber)} disabled={busy !== null}>{t("版本 {revision} · {date}", { revision: formatNumber(revision.revisionNumber, locale), date: formatEpochSeconds(revision.createdAtEpochSeconds, locale, t) })} · {formatBytes(revision.byteSize, locale, t)}</button>)}</div>}
            {selected.archive ? <div className="knowledge-archive" aria-label={t("离线归档信息")}><strong>{t("已保留离线归档")}</strong><dl className="tool-details"><dt>{t("格式")}</dt><dd>{archiveFormatLabel(selected.archive.format, t)}</dd><dt>{t("归档大小")}</dt><dd>{formatBytes(selected.archive.byteSize, locale, t)}</dd>{selected.archive.embeddedResourceCount != null && <><dt>{t("已嵌入资源")}</dt><dd>{formatNumber(selected.archive.embeddedResourceCount, locale)}</dd></>}{selected.archive.missingResourceCount != null && selected.archive.missingResourceCount > 0 && <><dt>{t("遗漏资源")}</dt><dd className="tool-warning">{t("{count} 个资源未能保留", { count: formatNumber(selected.archive.missingResourceCount, locale) })}</dd></>}{selected.archive.wasTruncated && <><dt>{t("完整性")}</dt><dd className="tool-warning">{t("归档内容曾被截断")}</dd></>}</dl><p className="tool-muted">{t("归档只作离线留存，不会在应用内执行或联网加载。")}</p></div> : null}
            <label htmlFor="knowledge-progress">{t("阅读进度 {percent}%", { percent: formatNumber(progressDraft ?? selected.readingProgressPercent, locale) })}<input id="knowledge-progress" type="range" min="0" max="100" value={progressDraft ?? selected.readingProgressPercent} onChange={(event) => setProgressDraft(clampProgress(Number(event.target.value)))} onPointerUp={(event) => void saveProgress(Number(event.currentTarget.value))} onKeyUp={(event) => void saveProgress(Number(event.currentTarget.value))} disabled={busy !== null} /></label>
            {sourceUrl && <a href={sourceUrl} target="_blank" rel="noopener noreferrer">{t("打开来源链接 ↗")}</a>}
            <div className="tool-actions"><button type="button" className="danger-action" onClick={() => void remove()} disabled={busy !== null}>{t("删除资料")}</button></div>
            {repository ? <div className="knowledge-export">
              <label htmlFor="knowledge-export-path">{t("导出到当前仓库（相对 .md 路径）")}<input id="knowledge-export-path" value={exportPath} onChange={(event) => setPath(event.target.value)} disabled={busy !== null} /></label>
              <button type="button" onClick={() => void exportItem()} disabled={busy !== null}>{plan ? t("确认执行导出") : t("生成导出计划")}</button>
              {plan && <div className="operation-plan"><p>{plan.summary}</p><p>{t("SHA-256：")}<code>{plan.contentSha256}</code></p><p>{t("有效至：{date}", { date: formatEpochSeconds(plan.expiresAtEpochSeconds, locale, t) })}</p>{plan.warnings.map((warning) => <p className="tool-warning" key={warning}>{warning}</p>)}</div>}
              {selected.archive && <div className="knowledge-archive-export"><label htmlFor="knowledge-archive-path">{t("导出离线归档（仓库相对路径）")}<input id="knowledge-archive-path" value={archivePath || defaultArchivePath(selected, selected.archive.format)} onChange={(event) => setArchivePath(event.target.value)} disabled={busy !== null} /></label><button type="button" onClick={() => void exportArchive()} disabled={busy !== null}>{archivePlan ? t("明确执行归档导出") : t("生成归档导出计划")}</button>{archivePlan && <div className="operation-plan"><p>{archivePlan.summary}</p><p>{t("格式：{format}；大小：{size}", { format: archiveFormatLabel(archivePlan.format, t), size: formatBytes(archivePlan.byteSize, locale, t) })}</p><p>{t("有效至：{date}", { date: formatEpochSeconds(archivePlan.expiresAtEpochSeconds, locale, t) })}</p>{archivePlan.warnings.map((warning) => <p className="tool-warning" key={warning}>{warning}</p>)}</div>}</div>}
            </div> : <p className="tool-muted">{t("打开一个仓库后，才可生成经确认的 Markdown 或离线归档导出计划。")}</p>}
          </section>}

          <section className="knowledge-section">
            <h2>{t("浏览器扩展配对")}</h2>
            <p className="tool-muted">{browser?.summary ?? t("正在读取本机桥状态…")}</p>
            {browser?.warning && <p className="tool-warning">{browser.warning}</p>}
            {browser?.endpoint && <p>{t("本机端点：")}<code>{browser.endpoint}</code></p>}
            {browser?.tokenExpiresAt != null && <p className="tool-muted">{t("令牌有效至：{date}", { date: formatEpochSeconds(browser.tokenExpiresAt, locale, t) })}</p>}
            {browser?.connectionToken && <div className="knowledge-token"><code aria-label={t("浏览器扩展配对令牌")}>{browser.connectionToken}</code><button type="button" onClick={() => void copyToken()}>{t("复制令牌")}</button></div>}
            <p className="tool-muted">{t("令牌只用于本机 Chrome/Firefox 扩展；轮换后旧令牌立即失效。")}</p>
            <button type="button" className="danger-action" disabled={!browser?.running || busy !== null} onClick={() => void rotate()}>{t("轮换令牌")}</button>
          </section>
        </div>
      </aside>
    </div>
  );
}

function sourceKindLabel(value: KnowledgeItemSummary["sourceKind"], t: UiTranslator): string { return { web: t("网页"), pdf: t("PDF"), text: t("文字") }[value]; }
function archiveFormatLabel(value: "html" | "mhtml", t: UiTranslator): string { return value === "mhtml" ? t("MHTML（含资源封装）") : t("离线 HTML（自包含）"); }
function sizeTemplate(value: number, locale: string): UiMessage { if (value < 1_024) return { source: "{bytes} 字节", parameters: { bytes: formatNumber(value, locale) } }; if (value < 1_024 * 1_024) return { source: "{value} KiB", parameters: { value: formatDecimal(value / 1_024, locale) } }; return { source: "{value} MiB", parameters: { value: formatDecimal(value / (1_024 * 1_024), locale) } }; }
function formatBytes(value: number, locale: string, t: UiTranslator): string { return renderUiMessage(sizeTemplate(value, locale), t); }
function formatNumber(value: number, locale: string): string { return value.toLocaleString(locale); }
function formatDecimal(value: number, locale: string): string { return value.toLocaleString(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }); }
function formatEpochSeconds(value: number, locale: string, t: UiTranslator = (source) => source): string { const date = new Date(value * 1_000); return Number.isNaN(date.getTime()) ? t("未知") : date.toLocaleString(locale); }
function renderKnowledgeMessage(message: KnowledgeUiMessage, locale: string, t: UiTranslator): string {
  const withSize = message.byteSize == null ? message : { ...message, labels: { ...message.labels, size: sizeTemplate(message.byteSize, locale) } };
  const withError = message.maskedError == null ? withSize : {
    ...withSize,
    parameters: { ...withSize.parameters, message: message.maskedError.map((part) => part === null ? t("[本地文件]") : part).join("") },
  };
  return renderUiMessage(withError, t);
}
function errorMessage(source: string, error: unknown): KnowledgeUiMessage { return { source, maskedError: messageFrom(error) }; }
function messageFrom(error: unknown): (string | null)[] {
  const value = error instanceof Error ? error.message : typeof error === "object" && error !== null && "message" in error ? String(error.message) : String(error);
  const parts: (string | null)[] = [];
  let offset = 0;
  for (const match of value.matchAll(/(?:[A-Za-z]:[\\/]|\/)[^\s，。；：:]+/g)) {
    parts.push(value.slice(offset, match.index), null);
    offset = match.index + match[0].length;
  }
  parts.push(value.slice(offset));
  return parts;
}
