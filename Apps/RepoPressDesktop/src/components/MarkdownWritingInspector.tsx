import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { MarkdownOutlineActions } from "./MarkdownOutlineActions";
import { MarkdownImageMetadataPanel } from "./MarkdownImageMetadataPanel";
import { MarkdownFindReplacePanel } from "./MarkdownFindReplacePanel";
import type { TextRange, WritingStats } from "../features/writing/markdownWriting";
import { getWritingStats } from "../features/writing/markdownWriting";
import { deleteMarkdownSection, duplicateMarkdownSection, getMarkdownSectionAnchor, getMarkdownSections, moveMarkdownSection } from "../features/writing/markdownPowerTools";
import { applyMarkdownDiagnosticFix, type MarkdownDiagnostic } from "../features/writing/markdownDiagnostics";
import { useMarkdownDiagnostics, type MarkdownDiagnosticsSession } from "../features/writing/useMarkdownDiagnostics";
import { MarkdownDiagnosticsState } from "./MarkdownDiagnosticsState";
import { useI18n, type MessageParameters } from "../i18n/i18n";
import { presentDiagnostic, renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import "./MarkdownWritingTools.css";

export interface MarkdownWritingInspectorProps {
  value: string;
  selection: TextRange;
  documentKey?: string;
  knownArticleTitles?: string[];
  stats?: WritingStats;
  diagnosticSession?: MarkdownDiagnosticsSession;
  onChange: (value: string, selection: TextRange, status?: string | UiMessage) => void;
  onLocate?: (range: TextRange, expectedText: string) => void;
  readOnly?: boolean;
  className?: string;
}

function diagnosticNotice(source: string, item: MarkdownDiagnostic, parameters?: MessageParameters): UiMessage {
  return item.presentation
    ? { source, parameters, labels: { title: item.presentation.title } }
    : { source, parameters: { ...parameters, title: item.title } };
}

export function MarkdownWritingInspector({ value, selection, documentKey, knownArticleTitles, stats: suppliedStats, diagnosticSession: suppliedSession, onChange, onLocate, readOnly = false, className = "" }: MarkdownWritingInspectorProps) {
  const { t } = useI18n();
  const [selectedSection, setSelectedSection] = useState<number | null>(null);
  const [outlineStatus, setOutlineStatus] = useState<UiMessage | null>(null);
  const [diagnosticStatus, setDiagnosticStatus] = useState<UiMessage | null>(null);
  const stats = useMemo(() => suppliedStats ?? getWritingStats(value), [suppliedStats, value]);
  const sections = useMemo(() => getMarkdownSections(value), [value]);
  const anchors = useMemo(() => sections.map((_, index) => getMarkdownSectionAnchor(value, index) ?? ""), [value, sections]);
  const localSession = useMarkdownDiagnostics(value, documentKey, knownArticleTitles, !suppliedSession);
  const candidateSession = suppliedSession ?? localSession;
  const diagnosticSession: MarkdownDiagnosticsSession = candidateSession.source === value && candidateSession.documentKey === documentKey
    ? candidateSession : { ...candidateSession, status: "idle", diagnostics: [] };
  const diagnostics = diagnosticSession.status === "ready" ? diagnosticSession.diagnostics : [];
  const diagnosticBinding = useRef({ value, documentKey, diagnostics });
  useLayoutEffect(() => { diagnosticBinding.current = { value, documentKey, diagnostics }; }, [value, documentKey, diagnostics]);
  useEffect(() => { setDiagnosticStatus(null); }, [value, documentKey, knownArticleTitles]);

  useEffect(() => { if (selectedSection !== null && selectedSection >= sections.length) setSelectedSection(sections.length ? sections.length - 1 : null); }, [sections.length, selectedSection]);
  function selectSection(index: number) {
    const section = sections[index]; if (!section) return;
    setSelectedSection(index); setOutlineStatus(null); onChange(value, { from: section.from, to: section.from });
  }
  function applySectionAction(action: "up" | "down" | "duplicate" | "delete") {
    if (selectedSection === null || readOnly) return;
    if (action === "delete" && !window.confirm(t("删除“{title}”及其全部子章节？", { title: sections[selectedSection]?.title ?? t("所选章节") }))) return;
    const result = action === "duplicate" ? duplicateMarkdownSection(value, selectedSection) : action === "delete" ? deleteMarkdownSection(value, selectedSection) : moveMarkdownSection(value, selectedSection, action);
    if (!result) { setOutlineStatus({ source: action === "up" ? "已经是同级第一章" : action === "down" ? "已经是同级最后一章" : "章节没有变化" }); return; }
    const nextSections = getMarkdownSections(result.text);
    const nextSelected = nextSections.findIndex((section) => section.from === result.selection.from);
    setSelectedSection(action === "delete" ? null : nextSelected >= 0 ? nextSelected : null);
    onChange(result.text, result.selection);
    setOutlineStatus({ source: action === "delete" ? "章节已从编辑缓冲区删除，保存后写入磁盘" : action === "duplicate" ? "章节副本已插入编辑缓冲区" : "章节顺序已调整" });
  }
  async function copyAnchor(anchor: string) {
    try { await navigator.clipboard.writeText(`#${anchor}`); setOutlineStatus({ source: "已复制章节链接 #{anchor}", parameters: { anchor } }); }
    catch { setOutlineStatus({ source: "无法访问剪贴板，可手动复制 #{anchor}", parameters: { anchor } }); }
  }
  function diagnosticLine(item: MarkdownDiagnostic): number { return value.slice(0, item.range.from).split("\n").length; }
  function diagnosticIsCurrent(item: MarkdownDiagnostic): boolean {
    const current = diagnosticBinding.current;
    if (current.value === value && current.documentKey === documentKey && current.diagnostics.includes(item)) return true;
    setDiagnosticStatus({ source: "写作检查位置已经变化，请重新检查后再定位。" });
    return false;
  }
  function locateDiagnostic(item: MarkdownDiagnostic, first = false) {
    if (!diagnosticIsCurrent(item)) return;
    const range = first ? item.related?.range : item.range;
    if (!range || !Number.isInteger(range.from) || !Number.isInteger(range.to) || range.from < 0 || range.to < range.from || range.to > value.length) return;
    const line = value.slice(0, range.from).split("\n").length;
    setDiagnosticStatus(diagnosticNotice("已定位到第 {line} 行：{title}", item, { line }));
    if (onLocate) onLocate(range, value); else onChange(value, range);
  }
  function fixDiagnostic(item: MarkdownDiagnostic) {
    if (readOnly || !diagnosticIsCurrent(item)) return;
    const result = applyMarkdownDiagnosticFix(value, item);
    if (!result) { setDiagnosticStatus({ source: "文稿内容已经变化，请重新检查后再修复。" }); return; }
    const status = diagnosticNotice("已修复：{title}", item);
    setDiagnosticStatus(status); onChange(result.text, result.selection, status);
  }

  return <aside className={`markdown-writing-inspector ${className}`.trim()} aria-label={t("文档洞察与查找替换")}>
    {!suppliedStats && <section className="markdown-writing-inspector__section"><h2>{t("文档洞察")}</h2><div className="markdown-writing-stats"><span>{t("字词 {count}", { count: stats.words })}</span><span>{t("字符 {count}", { count: stats.characters })}</span><span>{t("行数 {count}", { count: stats.lines })}</span><span>{t("阅读约 {minutes} 分钟", { minutes: stats.readingMinutes })}</span></div></section>}
    <section className="markdown-writing-inspector__section" aria-label={t("Markdown 写作诊断")}>
      <div className="markdown-diagnostics__heading"><h2>{t("写作诊断")}</h2><span>{diagnostics.length}</span></div>
      <MarkdownDiagnosticsState session={diagnosticSession} />
      {diagnosticSession.status === "ready" && !diagnostics.length && <p className="markdown-writing-muted">{t("未发现常见的结构或链接问题。")}</p>}
      {diagnostics.length > 0 && <ol className="markdown-diagnostics__list">{diagnostics.slice(0, 50).map((item) => {
        const display = presentDiagnostic(item, t);
        return <li key={item.id} className={`markdown-diagnostics__item markdown-diagnostics__item--${item.severity}`}><div><strong>{display.title}</strong><small>{t("第 {line} 行 · {severity}", { line: diagnosticLine(item), severity: t(item.severity === "error" ? "需要处理" : "建议检查") })}</small></div><p>{display.message}</p><div className="markdown-diagnostics__actions"><button type="button" onClick={() => locateDiagnostic(item)}>{t("定位")}</button>{item.related && <button type="button" onClick={() => locateDiagnostic(item, true)}>{t("定位首个标题")}</button>}{item.replacement !== undefined && <button type="button" disabled={readOnly} onClick={() => fixDiagnostic(item)}>{t("快速修复")}</button>}</div></li>;
      })}</ol>}
      {diagnostics.length > 50 && <p className="markdown-writing-muted">{t("另有 {count} 项；处理前面的项目后会继续显示。", { count: diagnostics.length - 50 })}</p>}
      <small className="markdown-writing-outline-status" aria-live="polite">{diagnosticStatus ? renderUiMessage(diagnosticStatus, t) : ""}</small>
    </section>
    <MarkdownFindReplacePanel value={value} selection={selection} documentKey={documentKey} readOnly={readOnly} onChange={onChange} onLocate={onLocate} />
    <MarkdownOutlineActions sections={sections} selectedIndex={selectedSection} readOnly={readOnly} anchors={anchors} onSelect={selectSection} onMove={(direction) => applySectionAction(direction)} onDuplicate={() => applySectionAction("duplicate")} onDelete={() => applySectionAction("delete")} onCopyAnchor={(anchor) => void copyAnchor(anchor)} />
    <small className="markdown-writing-outline-status" aria-live="polite">{outlineStatus ? renderUiMessage(outlineStatus, t) : ""}</small>
    <MarkdownImageMetadataPanel value={value} selection={selection} disabled={readOnly} onChange={onChange} />
  </aside>;
}
