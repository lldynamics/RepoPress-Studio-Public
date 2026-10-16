import { useLayoutEffect, useRef, useState } from "react";
import type { RepositoryImage, RepositoryImageSnapshot } from "../contracts/images";
import type { ImageReferenceFinding } from "../contracts/imageReferences";
import "./ImageReferenceRepairPanel.css";

export interface ImageReferenceRepairPanelProps {
  finding: ImageReferenceFinding | null;
  images: RepositoryImageSnapshot | null;
  selectedImagePath: string | null;
  replacementTarget: string | null;
  disabled: boolean;
  onSelectImage: (path: string) => void;
  onCancel: () => void;
  onApply: (image: RepositoryImage, replacementTarget: string) => Promise<boolean>;
}

/** This panel is intentionally a buffer-only preview. The parent rechecks the
 * selected inventory image immediately before it asks the editor to change. */
export function ImageReferenceRepairPanel({ finding, images, selectedImagePath, replacementTarget, disabled, onSelectImage, onCancel, onApply }: ImageReferenceRepairPanelProps) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const generation = useRef(0);
  const panel = useRef<HTMLElement>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const focusedFinding = useRef<string | null>(null);
  const selected = images?.images.find((image) => image.relativePath === selectedImagePath) ?? null;

  useLayoutEffect(() => { generation.current += 1; setBusy(false); setError(""); }, [finding?.id, replacementTarget, selected?.relativePath, selected?.sha256]);
  useLayoutEffect(() => {
    if (!finding?.repairTarget || focusedFinding.current === finding.id) return;
    focusedFinding.current = finding.id;
    panel.current?.scrollIntoView?.({ block: "nearest" });
    heading.current?.focus({ preventScroll: true });
  }, [finding?.id, finding?.repairTarget]);
  if (!finding?.repairTarget) return null;

  async function apply() {
    if (!selected || !replacementTarget || busy || disabled) return;
    const current = ++generation.current;
    setBusy(true); setError("");
    try {
      const applied = await onApply(selected, replacementTarget);
      if (current !== generation.current) return;
      if (!applied) setError("文章、图片或修复预览已变化；未应用替换，请重新检查。");
    } catch (reason) {
      if (current === generation.current) setError(reason instanceof Error && reason.message ? reason.message : "无法验证图片并应用修复。");
    } finally { if (current === generation.current) setBusy(false); }
  }

  return <section ref={panel} className="image-reference-repair" aria-label="修复单个图片引用" aria-busy={busy}>
    <header><h3 ref={heading} tabIndex={-1}>修复此图片引用</h3><button type="button" onClick={onCancel} disabled={busy}>取消</button></header>
    <p>只替换当前内联 Markdown 的图片目标；Alt 文本、标题、Front Matter 和其他相同引用保持不变。更改只会进入当前编辑缓冲区。</p>
    <dl><div><dt>文章</dt><dd><code>{finding.documentPath}:{finding.line}</code></dd></div><div><dt>替换前目标</dt><dd><code>{finding.repairTarget.expectedText}</code></dd></div><div><dt>替换后目标</dt><dd><code>{replacementTarget ?? "请先选择已扫描的图片"}</code></dd></div></dl>
    <label>替换为仓库图片<select aria-label="替换为仓库图片" value={selectedImagePath ?? ""} disabled={disabled || busy || !images} onChange={(event) => onSelectImage(event.target.value)}><option value="">选择已扫描的图片</option>{images?.images.map((image) => <option key={`${image.relativePath}:${image.sha256}`} value={image.relativePath}>{image.relativePath}</option>)}</select></label>
    <button type="button" className="primary" onClick={() => void apply()} disabled={!selected || !replacementTarget || disabled || busy}>确认验证并应用此预览</button>
    {error && <p className="error" role="alert">{error}</p>}
  </section>;
}

export default ImageReferenceRepairPanel;
