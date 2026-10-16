import { useEffect, useMemo, useRef, useState } from "react";
import type { MarkdownFileEntry, RepositorySessionSnapshot } from "../contracts/repository";
import type { TextRange } from "../features/writing/markdownWriting";
import {
  applyInternalLink,
  findInternalLinkQuery,
  getInternalLinkSuggestions,
  insertInternalLink,
  type MarkdownInternalLinkSuggestion,
} from "../features/writing/markdownInternalLinks";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { useI18n } from "../i18n/i18n";
import { internalLinkMessages } from "../i18n/internalLinkMessages";
import "./MarkdownLibraryPanels.css";

export interface MarkdownInternalLinkPickerProps {
  open: boolean;
  files: MarkdownFileEntry[];
  currentPath?: string;
  repository: RepositorySessionSnapshot;
  value: string;
  selection: TextRange;
  disabled?: boolean;
  resolveSuggestion?: (suggestion: MarkdownInternalLinkSuggestion) => Promise<MarkdownInternalLinkSuggestion>;
  onClose: () => void;
  onChange: (value: string, selection: TextRange, status: string) => void;
}

export function MarkdownInternalLinkPicker({ open, files, currentPath, repository, value, selection, disabled = false, resolveSuggestion, onClose, onChange }: MarkdownInternalLinkPickerProps) {
  const { t } = useI18n(internalLinkMessages);
  const translatorRef = useRef(t);
  translatorRef.current = t;
  const searchRef = useRef<HTMLInputElement>(null);
  const modalRoot = useRef<HTMLDivElement>(null);
  useDrawerFocus(open, modalRoot, onClose);
  const activeQuery = useMemo(() => findInternalLinkQuery(value, selection.to), [selection.to, value]);
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("");
  const [applyingPath, setApplyingPath] = useState<string | null>(null);
  const applyGeneration = useRef(0);
  const openRef = useRef(open);
  openRef.current = open;
  useEffect(() => { if (open) { setQuery(activeQuery?.query ?? ""); setStatus(""); } }, [activeQuery?.query, open]);
  useEffect(() => { if (!open) { applyGeneration.current += 1; setApplyingPath(null); } }, [open]);
  useEffect(() => {
    if (!open) return;
    const id = window.requestAnimationFrame(() => searchRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [open]);
  const suggestions = useMemo(() => getInternalLinkSuggestions(files, currentPath ?? "", repository, query), [currentPath, files, query, repository]);
  if (!open) return null;
  async function apply(suggestion: MarkdownInternalLinkSuggestion) {
    if (disabled) return;
    const generation = ++applyGeneration.current;
    setApplyingPath(suggestion.path); setStatus(resolveSuggestion ? "正在读取目标文章信息…" : "");
    let resolved = suggestion;
    if (resolveSuggestion) {
      try { resolved = await resolveSuggestion(suggestion); }
      catch { if (generation === applyGeneration.current) setStatus("无法读取目标文章元数据，已使用文件路径生成链接。"); }
    }
    if (generation !== applyGeneration.current || !openRef.current) return;
    const latest = findInternalLinkQuery(value, selection.to);
    const result = latest ? applyInternalLink(value, latest, resolved) : insertInternalLink(value, selection, resolved);
    if (!result) { setApplyingPath(null); setStatus("链接位置已变化，请重新打开选择器。"); return; }
    onChange(result.text, result.selection, translatorRef.current("已链接到“{label}”", { label: resolved.label }));
    onClose();
  }
  return <div ref={modalRoot} className="markdown-library-scrim" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="markdown-library-dialog" role="dialog" aria-modal="true" aria-labelledby="markdown-internal-link-title">
      <header><div><h2 id="markdown-internal-link-title">{t("插入内部链接")}</h2><p>{t("搜索当前站点的 Markdown 文档；链接目标会使用站点路由。")}</p></div><button className="markdown-library-close" type="button" onClick={onClose} aria-label={t("关闭内部链接选择器")}>×</button></header>
      <div className="markdown-library-content"><input ref={searchRef} className="markdown-library-search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder={t("搜索标题或路径")} aria-label={t("搜索内部链接目标")} />
        <div className="markdown-library-list">{suggestions.length ? suggestions.map((suggestion) => <article className="markdown-library-item" key={suggestion.path}><div><h3>{suggestion.label}</h3><p className="markdown-link-label">{suggestion.path}</p><span className="markdown-link-destination">{suggestion.url}</span></div><div className="markdown-library-item-actions"><button type="button" disabled={disabled || applyingPath !== null} onClick={() => void apply(suggestion)}>{applyingPath === suggestion.path ? t("正在读取…") : t("插入链接")}</button></div></article>) : <p className="markdown-library-empty">{t("没有匹配的 Markdown 文档。")}</p>}</div>
        <p className="markdown-library-status" aria-live="polite">{t(status)}</p>
      </div>
    </section>
  </div>;
}
