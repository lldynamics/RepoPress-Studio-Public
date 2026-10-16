import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { RepositoryImage, RepositoryImagePreview, RepositoryImageSnapshot } from "../contracts/images";
import type { ImageReferenceFinding, ImageReferenceOverlay, ImageReferenceRepairEdit } from "../contracts/imageReferences";
import { repositoryImageMarkdownPath } from "../features/images/repositoryImages";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { ImageReferenceCheckPanel } from "./ImageReferenceCheckPanel";
import { ImageReferenceRepairPanel } from "./ImageReferenceRepairPanel";
import "./ImageWorkbench.css";

export interface ImageWorkbenchProps {
  open: boolean;
  onClose: () => void;
  gateway: RepositoryGateway;
  repository: RepositorySessionSnapshot | null;
  enabled: boolean;
  canInsert: boolean;
  onInsert: (image: RepositoryImage, altText: string) => Promise<boolean>;
  onImport?: () => Promise<void>;
  referenceCheckEnabled?: boolean;
  referenceOverlay?: ImageReferenceOverlay;
  referenceDocumentKey?: string;
  onRepair?: (edit: ImageReferenceRepairEdit) => boolean;
}

type Sort = "name" | "size";
const MIME_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
const MAX_PREVIEW_BYTES = 8 * 1024 * 1024;

function messageFrom(reason: unknown, fallback: string) {
  if (reason instanceof Error && reason.message) return reason.message;
  if (reason && typeof reason === "object" && "message" in reason && typeof reason.message === "string") return reason.message;
  return fallback;
}

function formatBytes(value: number) {
  if (value < 1024) return `${Math.round(value)} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MiB`;
}

function warningText(warning: string) {
  const code = warning.split(":", 1)[0];
  const labels: Record<string, string> = {
    image_inventory_limit_reached: "图片数量达到扫描上限。",
    image_total_byte_limit_reached: "本次图片读取达到 64 MiB 上限。",
    image_file_too_large: "有图片超过单张 8 MiB 的读取上限。",
    image_depth_limit_reached: "有目录层级过深，未继续扫描。",
    image_entry_limit_reached: "仓库目录项达到扫描上限。",
    image_candidate_path_limit_reached: "图片路径清单达到容量上限。",
    image_directory_read_failed: "有目录无法读取。",
    image_directory_entry_failed: "有目录项无法读取。",
    image_entry_unavailable: "有文件在扫描时已不可用。",
    image_changed_during_scan: "有图片在扫描期间发生变化。",
    image_read_failed: "有图片读取失败。",
    image_symlink_skipped: "已跳过符号链接。",
    image_special_file_skipped: "已跳过非常规文件。",
    image_path_not_utf8: "有路径无法显示为 UTF-8 文本。",
    image_svg_not_supported: "SVG 暂不支持预览，已跳过。",
    image_signature_invalid: "有文件不是可识别的图片。",
    image_extension_mismatch: "有图片的扩展名与实际格式不符。",
    image_pixel_limit_exceeded: "有图片的尺寸超过预览上限。",
    image_dimensions_unknown: "有图片无法确认尺寸，已跳过。",
    image_candidate_limit_reached: "图片候选清单达到数量上限。",
    image_directory_changed: "有目录在扫描期间发生变化，已跳过。",
    image_dimensions_unavailable: "有图片无法确认尺寸，已跳过。",
    image_scan_limit: "扫描达到读取上限。",
    image_decode_failed: "有图片无法解码。",
    image_permission_denied: "有图片因权限未能读取。",
  };
  return labels[code] ?? (code.startsWith("image_") ? "部分图片未能安全读取，请检查仓库后重新扫描。" : warning);
}

async function previewDataUrl(preview: RepositoryImagePreview, image: RepositoryImage): Promise<string> {
  if (preview.relativePath !== image.relativePath || preview.sha256 !== image.sha256 || !/^[a-f0-9]{64}$/i.test(image.sha256) || !/^[a-f0-9]{64}$/i.test(preview.sha256) || !MIME_TYPES.has(preview.mimeType)) {
    throw new Error("预览响应与所选图片不匹配。");
  }
  if (preview.mimeType !== image.mimeType || !/^[A-Za-z0-9+/]*={0,2}$/.test(preview.dataBase64) || preview.dataBase64.length % 4 !== 0 || preview.dataBase64.length === 0 || preview.dataBase64.length > Math.ceil(MAX_PREVIEW_BYTES / 3) * 4) {
    throw new Error("预览数据格式无效。");
  }
  let bytes: Uint8Array;
  try {
    const binary = atob(preview.dataBase64);
    bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  } catch { throw new Error("预览数据格式无效。"); }
  if (bytes.length === 0 || bytes.length > MAX_PREVIEW_BYTES || bytes.length !== image.byteSize) throw new Error("预览大小与图片记录不匹配。");
  if (typeof crypto === "undefined" || !crypto.subtle) throw new Error("当前环境无法校验图片完整性。");
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const digestHex = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  if (digestHex.toLowerCase() !== image.sha256.toLowerCase()) throw new Error("预览完整性校验失败。");
  return `data:${preview.mimeType};base64,${preview.dataBase64}`;
}

export function ImageWorkbench({ open, onClose, gateway, repository, enabled, canInsert, onInsert, onImport, referenceCheckEnabled = false, referenceOverlay, referenceDocumentKey, onRepair }: ImageWorkbenchProps) {
  const root = useRef<HTMLDivElement>(null);
  const detail = useRef<HTMLElement>(null);
  const titleId = useId();
  const generation = useRef(0);
  const [snapshot, setSnapshot] = useState<RepositoryImageSnapshot | null>(null);
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [mimeFilter, setMimeFilter] = useState("all");
  const [sort, setSort] = useState<Sort>("name");
  const [scanBusy, setScanBusy] = useState(false);
  const [actionBusy, setActionBusy] = useState(false);
  const [previewBusy, setPreviewBusy] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [altText, setAltText] = useState("");
  const [importBusy, setImportBusy] = useState(false);
  const [repairFinding, setRepairFinding] = useState<ImageReferenceFinding | null>(null);
  const [repairBusy, setRepairBusy] = useState(false);
  const repairAttempt = useRef(0);
  const sessionId = repository?.sessionId ?? null;
  const selected = snapshot?.images.find((image) => image.relativePath === selectedPath) ?? null;
  const latestRepair = useRef({ open, enabled, canInsert, repository, referenceDocumentKey, referenceOverlay, snapshot, selectedPath, repairFinding, onRepair });
  latestRepair.current = { open, enabled, canInsert, repository, referenceDocumentKey, referenceOverlay, snapshot, selectedPath, repairFinding, onRepair };
  const repairPlan = useMemo(() => {
    if (!repairFinding?.repairTarget || !selected || !repository || repairFinding.documentPath !== referenceOverlay?.relativePath) return null;
    try { return repositoryImageMarkdownPath(selected.relativePath, repository, repairFinding.documentPath); }
    catch { return null; }
  }, [referenceOverlay?.relativePath, repairFinding, repository, selected]);
  function clearRepair() { repairAttempt.current += 1; setRepairBusy(false); setRepairFinding(null); }
  const close = useCallback(() => { if (actionBusy || importBusy || repairBusy) return; generation.current += 1; clearRepair(); onClose(); }, [actionBusy, importBusy, onClose, repairBusy]);

  useDrawerFocus(open, root, close);

  useLayoutEffect(() => {
    generation.current += 1;
    setSnapshot(null); setSelectedPath(null); setPreviewUrl(null); setError(""); setStatus(""); setAltText(""); setScanBusy(false); setActionBusy(false); setImportBusy(false); setPreviewBusy(false); clearRepair();
    return () => { generation.current += 1; };
  }, [gateway, open, sessionId, enabled]);

  useLayoutEffect(() => { clearRepair(); }, [referenceDocumentKey, referenceOverlay?.relativePath, referenceOverlay?.text, sessionId, snapshot]);

  const visibleImages = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase();
    return [...(snapshot?.images ?? [])]
      .filter((image) => (!needle || image.relativePath.toLocaleLowerCase().includes(needle)) && (mimeFilter === "all" || image.mimeType === mimeFilter))
      .sort((left, right) => sort === "size" ? right.byteSize - left.byteSize || left.relativePath.localeCompare(right.relativePath) : left.relativePath.localeCompare(right.relativePath));
  }, [mimeFilter, query, snapshot, sort]);

  const scan = useCallback(async () => {
    if (!enabled || !sessionId || scanBusy || previewBusy || actionBusy || importBusy || repairBusy) return;
    clearRepair();
    const current = ++generation.current;
    setScanBusy(true); setError(""); setStatus("正在扫描图片…"); setSnapshot(null); setSelectedPath(null); setPreviewUrl(null);
    try {
      const next = await gateway.inspectRepositoryImages(sessionId);
      if (current !== generation.current) return;
      setSnapshot(next); setStatus(next.truncated || next.omittedFiles > 0 || next.warnings.length > 0 ? "扫描完成，结果不完整。" : `扫描完成，共 ${next.images.length} 张图片。`);
    } catch (reason) { if (current === generation.current) { setError(messageFrom(reason, "无法扫描仓库图片。")); setStatus(""); } }
    finally { if (current === generation.current) setScanBusy(false); }
  }, [actionBusy, enabled, gateway, importBusy, previewBusy, repairBusy, scanBusy, sessionId]);

  useEffect(() => {
    if (!open || !selected || !sessionId || !enabled) { setPreviewUrl(null); setPreviewBusy(false); return; }
    const current = ++generation.current;
    setPreviewBusy(true); setPreviewUrl(null); setError("");
    void gateway.readRepositoryImage(sessionId, selected.relativePath, selected.sha256)
      .then((preview) => previewDataUrl(preview, selected))
      .then((url) => { if (current === generation.current) setPreviewUrl(url); })
      .catch((reason) => { if (current === generation.current) setError(messageFrom(reason, "无法读取图片预览。")); })
      .finally(() => { if (current === generation.current) setPreviewBusy(false); });
  }, [enabled, gateway, open, selected, sessionId]);

  async function insert() {
    if (!selected || !canInsert || actionBusy || previewBusy || scanBusy || importBusy || !previewUrl) return;
    const current = generation.current;
    setActionBusy(true); setError(""); setStatus("正在插入图片…");
    try { const inserted = await onInsert(selected, altText); if (current !== generation.current) return; setStatus(inserted ? "图片已插入当前文章。" : "插入未完成，文章没有改变。"); }
    catch (reason) { if (current === generation.current) { setError(messageFrom(reason, "插入图片失败。")); setStatus(""); } }
    finally { if (current === generation.current) setActionBusy(false); }
  }

  async function importImage() {
    if (!onImport || importBusy || scanBusy || actionBusy || previewBusy) return;
    const current = generation.current;
    setImportBusy(true); setError(""); setStatus("正在导入图片…");
    try { await onImport(); if (current === generation.current) setStatus("图片导入已完成，请重新扫描以刷新列表。"); }
    catch (reason) { if (current === generation.current) { setError(messageFrom(reason, "导入图片失败。")); setStatus(""); } }
    finally { if (current === generation.current) setImportBusy(false); }
  }

  async function applyReferenceRepair(image: RepositoryImage, replacementTarget: string): Promise<boolean> {
    const finding = repairFinding;
    const imageSnapshot = snapshot;
    const source = referenceOverlay?.text;
    const target = finding?.repairTarget;
    const documentKey = referenceDocumentKey;
    const targetRepository = repository;
    if (!finding || !target || !imageSnapshot || !source || !documentKey || !targetRepository || !onRepair || !canInsert || actionBusy || scanBusy || importBusy || repairBusy || previewBusy || finding.source !== "editor" || finding.documentPath !== referenceOverlay?.relativePath) return false;
    if (target.from < 0 || target.to < target.from || target.to > source.length || source.slice(target.from, target.to) !== target.expectedText) return false;
    let plannedTarget: string;
    try { plannedTarget = repositoryImageMarkdownPath(image.relativePath, targetRepository, finding.documentPath); }
    catch { return false; }
    if (replacementTarget !== plannedTarget || selectedPath !== image.relativePath) return false;
    const current = ++repairAttempt.current;
    setRepairBusy(true); setError(""); setStatus("正在验证替换图片…");
    try {
      const verified = await gateway.readRepositoryImage(targetRepository.sessionId, image.relativePath, image.sha256);
      await previewDataUrl(verified, image);
      const latest = latestRepair.current;
      const latestImage = latest.snapshot?.images.find((item) => item.relativePath === image.relativePath);
      if (current !== repairAttempt.current || !latest.open || !latest.enabled || !latest.canInsert || latest.repairFinding !== finding || latest.snapshot !== imageSnapshot || latest.repository?.sessionId !== targetRepository.sessionId || latest.referenceDocumentKey !== documentKey || latest.referenceOverlay?.relativePath !== finding.documentPath || latest.referenceOverlay?.text !== source || latest.selectedPath !== image.relativePath || latestImage?.sha256 !== image.sha256 || latest.onRepair !== onRepair) {
        throw new Error("修复预览已失效，请重新检查。");
      }
      if (source.slice(target.from, target.to) !== target.expectedText) throw new Error("图片目标位置已变化，请重新检查。");
      const latestTarget = repositoryImageMarkdownPath(latestImage.relativePath, latest.repository, finding.documentPath);
      if (latestTarget !== replacementTarget) throw new Error("替换预览已失效，请重新检查。");
      const nextText = source.slice(0, target.from) + replacementTarget + source.slice(target.to);
      const applied = onRepair({ documentKey, relativePath: finding.documentPath, expectedText: source, nextText, selection: { from: target.from, to: target.from + replacementTarget.length } });
      if (!applied) throw new Error("当前文章不可写或已变化，未应用替换。");
      setRepairFinding(null); setStatus("已替换当前编辑缓冲区中的一个图片目标，尚未写入磁盘。");
      return true;
    } catch (reason) {
      const message = messageFrom(reason, "无法验证图片并应用修复。");
      if (current === repairAttempt.current) { setError(message); setStatus(""); }
      throw new Error(message);
    } finally { if (current === repairAttempt.current) setRepairBusy(false); }
  }

  if (!open) return null;
  if (!enabled || !repository) return <div ref={root} className="image-workbench-scrim" role="presentation"><section className="image-workbench" role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1}><header><div><h2 id={titleId}>图片工作台</h2><p>{enabled ? "请先选择一个本地仓库。" : "浏览器演示不读取本地图片，请在桌面应用中使用。"}</p></div><button type="button" onClick={onClose} aria-label="关闭图片工作台">×</button></header><main><p role="status">{enabled ? "打开仓库后即可浏览图片。" : "图片工作台不可用。"}</p></main></section></div>;

  return <div ref={root} className="image-workbench-scrim" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) close(); }}>
    <section className="image-workbench" role="dialog" aria-modal="true" aria-labelledby={titleId} aria-busy={scanBusy || actionBusy || previewBusy || importBusy || repairBusy} tabIndex={-1}>
      <header><div><h2 id={titleId}>图片工作台</h2><p>已打开仓库：<code>{repository.rootPath}</code></p></div><button type="button" onClick={close} disabled={actionBusy || importBusy || repairBusy} aria-label="关闭图片工作台">×</button></header>
      <main>
        <div className="image-workbench-actions"><button type="button" className="primary" onClick={() => void scan()} disabled={scanBusy || previewBusy || actionBusy || importBusy || repairBusy}>{snapshot ? "重新扫描" : "扫描图片"}</button>{onImport && <button type="button" onClick={() => void importImage()} disabled={scanBusy || previewBusy || actionBusy || importBusy || repairBusy}>导入图片</button>}</div>
        <div className="image-workbench-filters"><label>搜索路径<input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="例如 assets/cover.png" /></label><label>格式<select value={mimeFilter} onChange={(event) => setMimeFilter(event.target.value)}><option value="all">全部格式</option>{[...MIME_TYPES].map((mime) => <option key={mime} value={mime}>{mime.replace("image/", "").toUpperCase()}</option>)}</select></label><label>排序<select value={sort} onChange={(event) => setSort(event.target.value as Sort)}><option value="name">按名称</option><option value="size">按大小</option></select></label></div>
        <div className="image-workbench-status" aria-live="polite">{error && <p className="error" role="alert">{error}</p>}{status && <p>{status}</p>}</div>
        {!snapshot ? <p className="image-workbench-empty">尚未扫描。扫描只读取本地仓库图片，不会自动执行。</p> : <>
          <dl className="image-workbench-metrics"><div><dt>总张数</dt><dd>{snapshot.images.length}</dd></div><div><dt>总大小</dt><dd>{formatBytes(snapshot.images.reduce((total, image) => total + image.byteSize, 0))}</dd></div><div><dt>已扫描</dt><dd>{formatBytes(snapshot.scannedBytes)}</dd></div></dl>
          {(snapshot.truncated || snapshot.omittedFiles > 0 || snapshot.warnings.length > 0) && <div className="image-workbench-warnings" role="status"><strong>部分结果</strong>{snapshot.truncated && <span>扫描结果可能不完整。</span>}{snapshot.omittedFiles > 0 && <span>有 {snapshot.omittedFiles} 个文件未纳入。</span>}{snapshot.warnings.map((warning, index) => <span key={`${index}:${warning}`}>{warningText(warning)}</span>)}</div>}
          <div className="image-workbench-grid"><div className="image-workbench-list" aria-label="仓库图片" aria-busy={scanBusy}>{visibleImages.length === 0 ? <p>没有符合筛选条件的图片。</p> : visibleImages.map((image) => <button key={`${image.relativePath}:${image.sha256}`} type="button" disabled={actionBusy || importBusy || repairBusy} aria-pressed={image.relativePath === selectedPath} className={image.relativePath === selectedPath ? "selected" : ""} onClick={() => { setSelectedPath(image.relativePath); setAltText(image.fileName.replace(/\.[^.]+$/, "")); }}><strong>{image.fileName}</strong><span>{image.relativePath}</span><small>{image.mimeType} · {formatBytes(image.byteSize)}</small></button>)}</div>
            <aside ref={detail} tabIndex={-1} className="image-workbench-detail" aria-label="图片详情">{selected ? <><div className="image-workbench-preview">{previewBusy ? <p>正在读取预览…</p> : previewUrl ? <img src={previewUrl} alt={altText || selected.fileName} onError={() => { setPreviewUrl(null); setError("图片解码失败。"); }} /> : <p>预览不可用。</p>}</div><dl><div><dt>路径</dt><dd><code>{selected.relativePath}</code></dd></div><div><dt>尺寸</dt><dd>{selected.width && selected.height ? `${selected.width} × ${selected.height}` : "未知"}</dd></div><div><dt>体积</dt><dd>{formatBytes(selected.byteSize)}</dd></div></dl><label>Alt 文本<input value={altText} disabled={actionBusy || importBusy || repairBusy} maxLength={500} onChange={(event) => setAltText(event.target.value)} /></label><button type="button" className="primary" onClick={() => void insert()} disabled={!canInsert || scanBusy || actionBusy || importBusy || repairBusy || previewBusy || !previewUrl}>{canInsert ? "插入当前文章" : "当前不可插入"}</button></> : <p>选择图片后查看详情与预览。</p>}</aside></div>
        </>}
        <ImageReferenceCheckPanel
          gateway={gateway} repository={repository} images={snapshot} overlay={referenceOverlay}
          enabled={referenceCheckEnabled} locked={scanBusy || actionBusy || importBusy || repairBusy}
          selectedImagePath={selectedPath}
          repairEnabled={Boolean(canInsert && onRepair && referenceDocumentKey && referenceOverlay)}
          onRepair={(finding) => { if (!actionBusy && !importBusy && !repairBusy && finding.source === "editor" && finding.documentPath === referenceOverlay?.relativePath && finding.repairTarget) setRepairFinding(finding); }}
          onRepairInvalidated={clearRepair}
          onSelectImage={(path) => {
            if (actionBusy || importBusy || repairBusy) return;
            const image = snapshot?.images.find((item) => item.relativePath === path);
            if (image) {
              setSelectedPath(path); setAltText(image.fileName.replace(/\.[^.]+$/, ""));
              detail.current?.scrollIntoView?.({ block: "nearest" });
              detail.current?.focus({ preventScroll: true });
            }
          }}
        />
        <ImageReferenceRepairPanel
          finding={repairFinding} images={snapshot} selectedImagePath={selectedPath} replacementTarget={repairPlan}
          disabled={!canInsert || !onRepair || !referenceDocumentKey || scanBusy || actionBusy || importBusy || repairBusy || previewBusy}
          onSelectImage={(path) => { const image = snapshot?.images.find((item) => item.relativePath === path); if (image) { setSelectedPath(path); setAltText(image.fileName.replace(/\.[^.]+$/, "")); } }}
          onCancel={clearRepair}
          onApply={applyReferenceRepair}
        />
        <p className="image-workbench-boundary">支持浏览、预览、插入、只读引用检查及当前文章的单引用修复。复杂语法、非当前文章和批量修复暂未提供；压缩、裁剪、删除、去除 EXIF 与 AI 生成暂未提供。</p>
      </main>
    </section>
  </div>;
}

export default ImageWorkbench;
