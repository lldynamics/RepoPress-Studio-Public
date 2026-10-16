import { useLayoutEffect, useRef, useState } from "react";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { RepositoryImageSnapshot } from "../contracts/images";
import type { ImageReferenceFinding, ImageReferenceOverlay, ImageReferenceReport } from "../contracts/imageReferences";
import { startImageReferenceAnalysis, type ImageReferenceAnalysisTask } from "../features/images/imageReferenceAnalysis";
import { ImageReferenceReportView } from "./ImageReferenceReport";
import "./ImageReferenceCheckPanel.css";

export interface ImageReferenceCheckPanelProps {
  gateway: RepositoryGateway;
  repository: RepositorySessionSnapshot;
  images: RepositoryImageSnapshot | null;
  overlay?: ImageReferenceOverlay;
  enabled: boolean;
  locked: boolean;
  selectedImagePath: string | null;
  onSelectImage: (path: string) => void;
  repairEnabled?: boolean;
  onRepair?: (finding: ImageReferenceFinding) => void;
  onRepairInvalidated?: () => void;
}

export function ImageReferenceCheckPanel({ gateway, repository, images, overlay, enabled, locked, selectedImagePath, onSelectImage, repairEnabled = false, onRepair, onRepairInvalidated }: ImageReferenceCheckPanelProps) {
  const generation = useRef(0);
  const inFlight = useRef(false);
  const analysis = useRef<ImageReferenceAnalysisTask | null>(null);
  const [busy, setBusy] = useState(false);
  const [report, setReport] = useState<ImageReferenceReport | null>(null);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const sessionId = repository.sessionId;

  useLayoutEffect(() => {
    generation.current += 1;
    analysis.current?.cancel();
    analysis.current = null;
    inFlight.current = false;
    setBusy(false); setReport(null); setStatus(""); setError("");
    return () => {
      generation.current += 1;
      analysis.current?.cancel();
      analysis.current = null;
    };
  }, [gateway, sessionId, repository.siteKind, repository.contentRoot, images, enabled, overlay?.relativePath, overlay?.text]);

  function cancel() {
    generation.current += 1;
    analysis.current?.cancel(); analysis.current = null;
    inFlight.current = false;
    setBusy(false); setStatus("已取消检查。"); setError("");
  }

  async function scan() {
    if (!enabled || !images || locked || inFlight.current) return;
    onRepairInvalidated?.();
    const current = ++generation.current;
    inFlight.current = true;
    setBusy(true); setReport(null); setError(""); setStatus("正在读取文章…");
    try {
      const sources = await gateway.inspectContentHealthSources(sessionId);
      if (current !== generation.current) return;
      setStatus("正在检查图片引用与 Alt…");
      const task = startImageReferenceAnalysis({ sources, images, repository: { siteKind: repository.siteKind, contentRoot: repository.contentRoot }, overlay });
      analysis.current = task;
      const next = await task.promise;
      if (current !== generation.current) return;
      setReport(next); setStatus("检查完成。编辑内容或重新扫描图片后，请再次检查。");
    } catch (reason) {
      if (current !== generation.current) return;
      setError(reason instanceof Error ? reason.message : "无法检查图片引用，请检查仓库后重试。"); setStatus("");
    } finally {
      if (current === generation.current) {
        inFlight.current = false; analysis.current = null; setBusy(false);
      }
    }
  }

  return <section className="image-reference-check" aria-label="图片引用与 Alt 检查" aria-busy={busy}>
    <h3>图片引用与 Alt</h3>
    <p>检查{repository.contentRoot ? <>内容目录 <code>{repository.contentRoot}</code></> : "仓库中的 Markdown 文章"}，并纳入当前编辑缓冲区。结果用于人工核对。</p>
    <div className="image-reference-check-actions">
      <button type="button" onClick={() => void scan()} disabled={!enabled || !images || locked || busy}>检查引用与 Alt</button>
      {busy && <button type="button" onClick={cancel}>取消检查</button>}
    </div>
    {!enabled && <p>当前环境不支持读取文章进行检查。</p>}
    {enabled && !images && <p>先扫描图片，再检查引用。</p>}
    <div aria-live="polite">{status && <p>{status}</p>}{error && <p role="alert">{error}</p>}</div>
    {report && <ImageReferenceReportView report={report} selectedImagePath={selectedImagePath} onSelectImage={onSelectImage} repairEnabled={repairEnabled} onRepair={onRepair} />}
  </section>;
}
