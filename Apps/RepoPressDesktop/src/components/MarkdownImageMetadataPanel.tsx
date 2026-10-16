import { useEffect, useMemo, useState } from "react";
import type { TextRange } from "../features/writing/markdownWriting";
import {
  getMarkdownCoverImage,
  getMarkdownImageReferences,
  setMarkdownCoverImage,
  updateMarkdownImageMetadata,
  type MarkdownImageReference,
} from "../features/writing/markdownImageMetadata";
import { useI18n } from "../i18n/i18n";
import type { UiMessage } from "../i18n/uiMessage";
import "./MarkdownLibraryPanels.css";

export interface MarkdownImageMetadataPanelProps {
  value: string;
  selection: TextRange;
  disabled?: boolean;
  onChange: (value: string, selection: TextRange, status: string | UiMessage) => void;
}

function nearestReference(references: MarkdownImageReference[], selection: TextRange): MarkdownImageReference | null {
  const cursor = selection.from;
  return references.reduce<MarkdownImageReference | null>((nearest, reference) => {
    if (!nearest) return reference;
    const distance = cursor < reference.from ? reference.from - cursor : cursor > reference.to ? cursor - reference.to : 0;
    const previous = cursor < nearest.from ? nearest.from - cursor : cursor > nearest.to ? cursor - nearest.to : 0;
    return distance < previous ? reference : nearest;
  }, null);
}

export function MarkdownImageMetadataPanel({ value, selection, disabled = false, onChange }: MarkdownImageMetadataPanelProps) {
  const { t } = useI18n();
  const references = useMemo(() => getMarkdownImageReferences(value), [value]);
  const nearest = useMemo(() => nearestReference(references, selection), [references, selection]);
  const [selectedPath, setSelectedPath] = useState<string | null>(nearest?.path ?? null);
  const [alt, setAlt] = useState("");
  const [caption, setCaption] = useState("");
  const [status, setStatus] = useState<UiMessage | null>(null);
  useEffect(() => { setSelectedPath(nearest?.path ?? null); }, [nearest?.from, nearest?.path]);
  const selected = references.find((reference) => reference.path === selectedPath) ?? nearest;
  useEffect(() => { setAlt(selected?.alt ?? ""); setCaption(selected?.title ?? ""); }, [selected?.alt, selected?.path, selected?.title]);
  const cover = getMarkdownCoverImage(value);
  function choose(reference: MarkdownImageReference) { setSelectedPath(reference.path); setStatus(null); }
  function applyMetadata() {
    if (!selected || disabled) return;
    const result = updateMarkdownImageMetadata(value, selected.path, alt, caption);
    onChange(result.text, result.selection, { source: "已更新 {count} 个同路径图片引用的替代文本和说明。", parameters: { count: result.updatedCount } });
  }
  function updateCover(checked: boolean) {
    if (!selected || disabled) return;
    const result = setMarkdownCoverImage(value, checked ? selected.path : "", selection);
    if (result.text === value) { setStatus({ source: "Front Matter 当前无法安全编辑，请先修复其格式。" }); return; }
    onChange(result.text, result.selection, { source: checked ? "已将所选图片设为封面。" : "已清除封面图片。" });
  }
  return <section className="markdown-image-metadata" aria-labelledby="markdown-image-metadata-title">
    <h2 id="markdown-image-metadata-title">{t("图片元数据")}</h2><p>{t("说明会保存为 Markdown 图片标题；更新将应用于本文中相同路径的所有图片引用。")}</p>
    {references.length ? <><div className="markdown-image-reference-list" aria-label={t("文档中的图片")}>{references.map((reference) => <button className="markdown-image-reference" type="button" key={`${reference.path}-${reference.from}`} aria-pressed={selected?.path === reference.path} onClick={() => choose(reference)}><span>{reference.alt || t("未填写替代文本")}</span><small>{reference.path}</small></button>)}</div>
      {selected && <><label>{t("替代文本")}<input value={alt} disabled={disabled} onChange={(event) => setAlt(event.target.value)} /></label><label>{t("说明（图片标题）")}<input value={caption} disabled={disabled} onChange={(event) => setCaption(event.target.value)} /></label><label className="markdown-image-cover"><input type="checkbox" checked={cover === selected.path} disabled={disabled} onChange={(event) => updateCover(event.target.checked)} />{t("设为封面图片")}</label><div className="markdown-image-metadata-actions"><button type="button" disabled={disabled} onClick={applyMetadata}>{t("应用元数据")}</button></div></>}</> : <p className="markdown-library-empty">{t("本文没有可编辑的 Markdown 图片。")}</p>}
    <small aria-live="polite">{status ? t(status.source, status.parameters) : ""}</small>
  </section>;
}
