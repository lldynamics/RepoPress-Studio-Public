import { useEffect, useMemo, useRef, useState } from "react";
import { addDefaultFrontMatter, adjustSelectionAfterFrontMatterChange, parseFrontMatter, updateFrontMatterField, type FrontMatterField } from "../features/frontmatter/frontMatter";
import type { TextRange } from "../features/writing/markdownWriting";
import { renderUiMessage } from "../i18n/uiMessage";
import { useI18n } from "../i18n/i18n";
import "./FrontMatterPanel.css";

export interface FrontMatterFocusRequest {
  field: FrontMatterField;
  requestKey: number;
  expectedText: string;
}

export interface FrontMatterPanelProps {
  value: string;
  selection: TextRange;
  disabled?: boolean;
  focusRequest?: FrontMatterFocusRequest;
  onChange: (value: string, selection: TextRange) => void;
}

export function FrontMatterPanel({ value, selection, disabled = false, focusRequest, onChange }: FrontMatterPanelProps) {
  const { t } = useI18n();
  const [expanded, setExpanded] = useState(false);
  const snapshot = useMemo(() => parseFrontMatter(value), [value]);
  const handledRequest = useRef<number | null>(null);
  const pendingFocus = useRef<FrontMatterFocusRequest | null>(null);
  const addButton = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLElement>(null);
  const missingMessage = useRef<HTMLDivElement>(null);
  const warning = useRef<HTMLParagraphElement>(null);
  const fields = useRef<Partial<Record<FrontMatterField, HTMLInputElement>>>({});
  const fieldLabels = useRef<Partial<Record<FrontMatterField, HTMLLabelElement>>>({});
  const liveValue = useRef(value);
  const liveRequest = useRef(focusRequest);
  const liveDisabled = useRef(disabled);
  liveValue.current = value;
  liveRequest.current = focusRequest;
  liveDisabled.current = disabled;

  useEffect(() => {
    if (!focusRequest || handledRequest.current === focusRequest.requestKey || value !== focusRequest.expectedText) return;
    if (pendingFocus.current?.requestKey === focusRequest.requestKey) return;
    pendingFocus.current = focusRequest;
    setExpanded(true);
  }, [focusRequest, value]);

  useEffect(() => {
    const request = pendingFocus.current;
    if (!request || !expanded || value !== request.expectedText) return;
    let cancelled = false;
    queueMicrotask(() => {
      if (cancelled || liveValue.current !== request.expectedText || liveRequest.current?.requestKey !== request.requestKey) return;
      if (!snapshot) {
        if (liveDisabled.current) missingMessage.current?.focus();
        else addButton.current?.focus();
      } else if (snapshot.issue) warning.current?.focus();
      else if (liveDisabled.current) fieldLabels.current[request.field]?.focus();
      else fields.current[request.field]?.focus();
      handledRequest.current = request.requestKey;
      pendingFocus.current = null;
    });
    return () => { cancelled = true; };
  }, [expanded, focusRequest, snapshot, value]);

  function apply(field: FrontMatterField, nextValue: string | string[] | boolean) {
    const updated = updateFrontMatterField(value, field, nextValue);
    if (updated !== value) onChange(updated, adjustSelectionAfterFrontMatterChange(value, updated, selection));
  }

  if (!snapshot) return <section ref={panel} tabIndex={-1} className="front-matter-panel compact" aria-label={t("Front Matter 属性")}>
    <div ref={missingMessage} tabIndex={-1}><strong>Front Matter</strong><span>{t("当前文档还没有文章元数据")}</span></div>
    <button ref={addButton} type="button" disabled={disabled} onClick={() => {
      const updated = addDefaultFrontMatter(value);
      onChange(updated, adjustSelectionAfterFrontMatterChange(value, updated, selection));
      setExpanded(true);
    }}>{t("添加基础属性")}</button>
  </section>;

  if (!expanded) return <section ref={panel} tabIndex={-1} className="front-matter-panel compact" aria-label={t("Front Matter 属性")}>
    <button type="button" className="front-matter-summary" onClick={() => setExpanded(true)} aria-expanded="false">
      <strong>Front Matter</strong>
      <span>{(snapshot.issuePresentation ? renderUiMessage(snapshot.issuePresentation, t) : snapshot.issue) ?? t("{slug} · {count} 个标签 · {style}", { slug: snapshot.values.slug || t("未设置 slug"), count: snapshot.values.tags.length, style: snapshot.style.toUpperCase() })}</span>
    </button>
  </section>;

  return <section ref={panel} tabIndex={-1} className="front-matter-panel" aria-label={t("Front Matter 属性")}>
    <header><div><strong>Front Matter</strong><span>{t("{style} · 结构化属性", { style: snapshot.style.toUpperCase() })}</span></div><button type="button" onClick={() => { pendingFocus.current = null; if (focusRequest) handledRequest.current = focusRequest.requestKey; setExpanded(false); }} aria-label={t("折叠 Front Matter 属性")}>{t("收起")}</button></header>
    {snapshot.issue ? <p ref={warning} tabIndex={-1} className="front-matter-warning" role="alert">{t("{issue}。请直接在下方编辑器中修复；为避免损坏原文，属性回写已停用。", { issue: snapshot.issuePresentation ? renderUiMessage(snapshot.issuePresentation, t) : snapshot.issue })}</p> : <div className="front-matter-fields">
      <label ref={(node) => { fieldLabels.current.title = node ?? undefined; }} tabIndex={-1}>{t("标题")}<input ref={(node) => { fields.current.title = node ?? undefined; }} value={snapshot.values.title} disabled={disabled} onChange={(event) => apply("title", event.target.value)} /></label>
      <label ref={(node) => { fieldLabels.current.date = node ?? undefined; }} tabIndex={-1}>{t("日期")}<input ref={(node) => { fields.current.date = node ?? undefined; }} type="date" value={snapshot.values.date.slice(0, 10)} disabled={disabled} onChange={(event) => apply("date", event.target.value)} /></label>
      <label ref={(node) => { fieldLabels.current.slug = node ?? undefined; }} tabIndex={-1}>Slug<input ref={(node) => { fields.current.slug = node ?? undefined; }} value={snapshot.values.slug} disabled={disabled} spellCheck={false} onChange={(event) => apply("slug", event.target.value)} /></label>
      <label ref={(node) => { fieldLabels.current.permalink = node ?? undefined; }} tabIndex={-1}>{t("固定链接")}<input ref={(node) => { fields.current.permalink = node ?? undefined; }} value={snapshot.values.permalink} disabled={disabled} spellCheck={false} placeholder="/posts/example/" onChange={(event) => apply("permalink", event.target.value)} /></label>
      <label ref={(node) => { fieldLabels.current.cover = node ?? undefined; }} tabIndex={-1}>{t("封面路径")}<input ref={(node) => { fields.current.cover = node ?? undefined; }} value={snapshot.values.cover} disabled={disabled} spellCheck={false} placeholder="/images/cover.jpg" onChange={(event) => apply("cover", event.target.value)} /></label>
      <label ref={(node) => { fieldLabels.current.description = node ?? undefined; }} tabIndex={-1} className="wide">{t("摘要")}<input ref={(node) => { fields.current.description = node ?? undefined; }} value={snapshot.values.description} disabled={disabled} onChange={(event) => apply("description", event.target.value)} /></label>
      <label ref={(node) => { fieldLabels.current.tags = node ?? undefined; }} tabIndex={-1}>{t("标签")}<input ref={(node) => { fields.current.tags = node ?? undefined; }} key={`tags-${snapshot.values.tags.join("|")}`} defaultValue={snapshot.values.tags.join(", ")} disabled={disabled} placeholder={t("以逗号分隔")} onBlur={(event) => apply("tags", event.target.value.split(","))} onKeyDown={(event) => { if (event.key === "Enter") event.currentTarget.blur(); }} /></label>
      <label ref={(node) => { fieldLabels.current.categories = node ?? undefined; }} tabIndex={-1}>{t("分类")}<input ref={(node) => { fields.current.categories = node ?? undefined; }} key={`categories-${snapshot.values.categories.join("|")}`} defaultValue={snapshot.values.categories.join(", ")} disabled={disabled} placeholder={t("以逗号分隔")} onBlur={(event) => apply("categories", event.target.value.split(","))} onKeyDown={(event) => { if (event.key === "Enter") event.currentTarget.blur(); }} /></label>
      <label ref={(node) => { fieldLabels.current.draft = node ?? undefined; }} tabIndex={-1} className="front-matter-draft"><input ref={(node) => { fields.current.draft = node ?? undefined; }} type="checkbox" checked={snapshot.values.draft} disabled={disabled} onChange={(event) => apply("draft", event.target.checked)} />{t("保留为草稿")}</label>
    </div>}
  </section>;
}
