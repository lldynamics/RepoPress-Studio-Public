import { useEffect, useMemo, useRef, useState } from "react";
import type { TextRange } from "../features/writing/markdownWriting";
import { activeMarkdownOutlineItemId, markdownOutlineSignature, presentMarkdownOutline, visibleMarkdownOutlineItems } from "../features/writing/markdownOutlinePresentation";
import { useI18n } from "../i18n/i18n";
import "./MarkdownOutlinePanel.css";

export interface MarkdownOutlinePanelProps {
  value: string;
  selection: TextRange;
  documentKey: string;
  onLocate: (range: TextRange, expectedText: string) => void;
  onClose: () => void;
}

export function MarkdownOutlinePanel({ value, selection, documentKey, onLocate, onClose }: MarkdownOutlinePanelProps) {
  const { t } = useI18n();
  const presentation = useMemo(() => presentMarkdownOutline(value), [value]);
  const signature = markdownOutlineSignature(presentation.items);
  const [collapsed, setCollapsed] = useState<Set<string>>(() => new Set());
  const previousDocument = useRef(documentKey);
  const previousSignature = useRef(signature);
  const activeId = activeMarkdownOutlineItemId(presentation.items, selection);
  const visible = visibleMarkdownOutlineItems(presentation.items, collapsed);
  const activeRef = useRef<HTMLButtonElement>(null);
  const scrollRef = useRef<HTMLOListElement>(null);

  useEffect(() => {
    if (previousDocument.current !== documentKey) {
      setCollapsed(new Set());
      previousDocument.current = documentKey;
      previousSignature.current = signature;
      return;
    }
    if (previousSignature.current !== signature) {
      setCollapsed((current) => {
        const ids = new Set(presentation.items.map((item) => item.id));
        return new Set([...current].filter((id) => ids.has(id)));
      });
      previousSignature.current = signature;
    }
  }, [documentKey, presentation.items, signature]);

  useEffect(() => {
    const container = scrollRef.current;
    const active = activeRef.current;
    if (!container || !active || !activeId) return;
    const top = active.offsetTop - container.offsetTop;
    const bottom = top + active.offsetHeight;
    if (top < container.scrollTop) container.scrollTop = top;
    else if (bottom > container.scrollTop + container.clientHeight) container.scrollTop = bottom - container.clientHeight;
  }, [activeId]);

  function locate(item: typeof presentation.items[number]) {
    onLocate({ from: item.from, to: item.headingTo }, value);
  }

  return <aside className="markdown-outline-panel" aria-label={t("文章大纲")}>
    <header className="markdown-outline-panel__header">
      <h2>{t("文章大纲")}</h2>
      <span aria-live="polite">{presentation.isPartial ? t("显示 {shown}/{total} 个章节", { shown: presentation.items.length, total: presentation.totalCount }) : presentation.totalCount === 1 ? t("章节 1") : t("章节 {count}", { count: presentation.totalCount })}</span>
      <button type="button" className="markdown-outline-panel__close" onClick={onClose} aria-label={t("关闭文章大纲")}>×</button>
    </header>
    {presentation.items.length === 0 ? <p className="markdown-outline-panel__empty">{t("还没有可导航的标题")}</p> : <ol className="markdown-outline-panel__scroll" ref={scrollRef} aria-label={t("标题列表")}>
      {visible.map((item) => <li className="markdown-outline-panel__row" key={item.id}>
        <button type="button" className={`markdown-outline-panel__item${item.id === activeId ? " is-active" : ""}`} aria-current={item.id === activeId ? "location" : undefined} ref={item.id === activeId ? activeRef : undefined} onClick={() => locate(item)} style={{ paddingInlineStart: `${Math.max(0, item.level - 1) * 1.05 + 0.5}rem` }}>
          <span className="markdown-outline-panel__level">H{item.level}</span><span className="markdown-outline-panel__title">{item.title}</span>
        </button>
        {item.hasChildren && <button type="button" className="markdown-outline-panel__toggle" onClick={() => setCollapsed((current) => { const next = new Set(current); if (next.has(item.id)) next.delete(item.id); else next.add(item.id); return next; })} aria-label={collapsed.has(item.id) ? t("展开{title}", { title: item.title }) : t("折叠{title}", { title: item.title })} aria-expanded={!collapsed.has(item.id)}>{collapsed.has(item.id) ? "▸" : "▾"}</button>}
      </li>)}
    </ol>}
  </aside>;
}
