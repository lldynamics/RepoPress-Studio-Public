import { useEffect, useMemo, useRef, useState } from "react";
import type { TextRange } from "../features/writing/markdownWriting";
import {
  availableMarkdownSnippets,
  BUILT_IN_MARKDOWN_SNIPPETS,
  insertMarkdownSnippet,
  normalizeSnippetShortcut,
  removeCustomMarkdownSnippet,
  replaceCustomMarkdownSnippets,
  saveCustomMarkdownSnippet,
  type MarkdownSnippet,
  type MarkdownSnippetExpansionContext,
  type MarkdownSnippetKind,
} from "../features/writing/markdownSnippets";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { useI18n } from "../i18n/i18n";
import { snippetLibraryMessages } from "../i18n/snippetLibraryMessages";
import { writingBuiltinSnippetMessages } from "../i18n/writingBuiltinSnippetMessages";
import "./MarkdownLibraryPanels.css";

const messages = { ...snippetLibraryMessages, ...writingBuiltinSnippetMessages };

export const MARKDOWN_CUSTOM_SNIPPETS_STORAGE_KEY = "repopress.markdown-custom-snippets.v1";

export interface MarkdownSnippetLibraryProps {
  open: boolean;
  scope: string;
  context: MarkdownSnippetExpansionContext;
  value: string;
  selection: TextRange;
  disabled?: boolean;
  onClose: () => void;
  onChange: (value: string, selection: TextRange, status: string) => void;
  onCustomSnippetsChange?: (snippets: MarkdownSnippet[]) => void;
}

type SnippetFilter = "all" | "template" | "snippet";
interface SnippetDraft {
  label: string;
  shortcut: string;
  kind: MarkdownSnippetKind;
  template: string;
  description: string;
}
const emptyDraft = (): SnippetDraft => ({ label: "", shortcut: "", kind: "snippet", template: "", description: "" });

export function readStoredMarkdownSnippets(scope: string): MarkdownSnippet[] {
  try {
    const stored: unknown = JSON.parse(window.localStorage.getItem(MARKDOWN_CUSTOM_SNIPPETS_STORAGE_KEY) ?? "{}");
    if (!stored || typeof stored !== "object") return [];
    const items = (stored as Record<string, unknown>)[scope];
    if (!Array.isArray(items)) return [];
    const ids = new Set<string>(); const shortcuts = new Set<string>();
    return items.map(sanitizeSnippet).filter((snippet): snippet is MarkdownSnippet => Boolean(snippet)).filter((snippet) => {
      const shortcut = normalizeSnippetShortcut(snippet.shortcut);
      const valid = Boolean(snippet.label.trim() && snippet.template.trim() && shortcut)
        && !ids.has(snippet.id) && !shortcuts.has(shortcut)
        && !BUILT_IN_MARKDOWN_SNIPPETS.some((builtin) => builtin.id === snippet.id || builtin.shortcut === shortcut);
      if (valid) { ids.add(snippet.id); shortcuts.add(shortcut); }
      return valid;
    }).slice(-100);
  } catch { return []; }
}

function sanitizeSnippet(value: unknown): MarkdownSnippet | null {
  if (!value || typeof value !== "object") return null;
  const item = value as Partial<MarkdownSnippet>;
  if (typeof item.id !== "string" || !item.id.trim() || item.id.length > 128
    || typeof item.label !== "string" || item.label.length > 200
    || typeof item.shortcut !== "string" || item.shortcut.length > 80
    || typeof item.template !== "string" || item.template.length > 100_000
    || (item.kind !== "articleTemplate" && item.kind !== "snippet")
    || (item.description !== undefined && (typeof item.description !== "string" || item.description.length > 1_000))
    || (item.selectionToken !== undefined && (typeof item.selectionToken !== "string" || item.selectionToken.length > 1_000))) return null;
  const shortcut = normalizeSnippetShortcut(item.shortcut);
  if (!item.label.trim() || !item.template.trim() || !shortcut) return null;
  return {
    id: item.id,
    label: item.label.trim(),
    description: item.description?.trim() || undefined,
    shortcut,
    kind: item.kind,
    template: item.template,
    selectionToken: item.selectionToken || undefined,
  };
}

function persistCustomSnippets(scope: string, snippets: MarkdownSnippet[]): boolean {
  try {
    const stored: unknown = JSON.parse(window.localStorage.getItem(MARKDOWN_CUSTOM_SNIPPETS_STORAGE_KEY) ?? "{}");
    const byScope = stored && typeof stored === "object" ? stored as Record<string, unknown> : {};
    window.localStorage.setItem(MARKDOWN_CUSTOM_SNIPPETS_STORAGE_KEY, JSON.stringify({ ...byScope, [scope]: snippets }));
    return true;
  } catch { return false; }
}

function snippetLabel(snippet: MarkdownSnippet): string { return snippet.label; }
function snippetTemplate(snippet: MarkdownSnippet): string { return snippet.template; }
function draftFrom(snippet: MarkdownSnippet): SnippetDraft { return { label: snippetLabel(snippet), shortcut: snippet.shortcut, kind: snippet.kind, template: snippetTemplate(snippet), description: snippet.description ?? "" }; }

export function MarkdownSnippetLibrary({ open, scope, context, value, selection, disabled = false, onClose, onChange, onCustomSnippetsChange }: MarkdownSnippetLibraryProps) {
  const { t } = useI18n(messages);
  const displayLabel = (snippet: MarkdownSnippet) => BUILT_IN_MARKDOWN_SNIPPETS.includes(snippet) ? t(snippet.label) : snippet.label;
  const displayDescription = (snippet: MarkdownSnippet) => snippet.description && BUILT_IN_MARKDOWN_SNIPPETS.includes(snippet) ? t(snippet.description) : snippet.description;
  const searchRef = useRef<HTMLInputElement>(null);
  const modalRoot = useRef<HTMLDivElement>(null);
  useDrawerFocus(open, modalRoot, onClose);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<SnippetFilter>("all");
  const [customSnippets, setCustomSnippets] = useState<MarkdownSnippet[]>(() => readStoredMarkdownSnippets(scope));
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<MarkdownSnippet | null>(null);
  const [draft, setDraft] = useState<SnippetDraft>(emptyDraft);
  const [status, setStatus] = useState("");

  useEffect(() => {
    const restored = readStoredMarkdownSnippets(scope);
    const registered = replaceCustomMarkdownSnippets(scope, restored);
    setCustomSnippets(registered);
    onCustomSnippetsChange?.(registered);
    setFormOpen(false); setEditing(null); setDraft(emptyDraft()); setStatus("");
  }, [scope, onCustomSnippetsChange]);

  useEffect(() => {
    if (!open) return;
    const id = window.requestAnimationFrame(() => searchRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [open]);

  const snippets = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase();
    return availableMarkdownSnippets(scope, customSnippets).filter((snippet) => {
      const template = snippet.kind === "articleTemplate";
      const matchesKind = filter === "all" || (filter === "template" ? template : !template);
      const haystack = `${snippetLabel(snippet)} ${snippet.shortcut} ${snippet.description ?? ""} ${snippetTemplate(snippet)}`.toLocaleLowerCase();
      return matchesKind && (!normalized || haystack.includes(normalized));
    });
  }, [customSnippets, filter, query, scope]);

  if (!open) return null;

  function startCreate() { setFormOpen(true); setEditing(null); setDraft(emptyDraft()); setStatus(""); }
  function startEdit(snippet: MarkdownSnippet) { setFormOpen(true); setEditing(snippet); setDraft(draftFrom(snippet)); setStatus(""); }
  function updateDraft<K extends keyof SnippetDraft>(key: K, next: SnippetDraft[K]) { setDraft((current) => ({ ...current, [key]: next })); }
  function insert(snippet: MarkdownSnippet) {
    if (disabled) return;
    const result = insertMarkdownSnippet(value, selection, snippet, context);
    onChange(result.text, result.selection, t("已插入“{name}”", { name: displayLabel(snippet) }));
    onClose();
  }
  function save() {
    if (!draft.label.trim() || !draft.template.trim()) { setStatus("请填写片段名称和 Markdown 内容。"); return; }
    if (draft.label.length > 200 || draft.shortcut.length > 80 || draft.description.length > 1_000 || draft.template.length > 100_000) { setStatus("片段内容过长，请精简后再保存。"); return; }
    const normalizedShortcut = normalizeSnippetShortcut(draft.shortcut.trim() || draft.label.trim());
    if (!normalizedShortcut) { setStatus("请填写有效的快捷方式。"); return; }
    if (BUILT_IN_MARKDOWN_SNIPPETS.some((item) => item.shortcut === normalizedShortcut)) { setStatus("该快捷方式已被内置片段占用。"); return; }
    if (customSnippets.some((item) => item.id !== editing?.id && normalizeSnippetShortcut(item.shortcut) === normalizedShortcut)) { setStatus("该快捷方式已被此站点的另一条自定义片段占用。"); return; }
    const snippet: MarkdownSnippet = {
      id: editing?.id ?? `custom-${crypto.randomUUID()}`,
      label: draft.label.trim(), description: draft.description.trim() || undefined,
      shortcut: draft.shortcut.trim() || draft.label.trim(), kind: draft.kind,
      template: draft.template,
    };
    const next = saveCustomMarkdownSnippet(scope, snippet);
    const saved = next.some((item) => item.id === snippet.id && item.label === snippet.label && item.template === snippet.template && item.shortcut === normalizedShortcut);
    if (!saved) { setStatus("无法保存该片段。请检查名称、Markdown 和快捷方式。"); return; }
    if (!persistCustomSnippets(scope, next)) {
      replaceCustomMarkdownSnippets(scope, customSnippets);
      setStatus("本地存储不可用，片段未保存。");
      return;
    }
    setCustomSnippets(next); onCustomSnippetsChange?.(next);
    setFormOpen(false); setEditing(null); setDraft(emptyDraft()); setStatus("自定义片段已保存到此站点。");
  }
  function remove(snippet: MarkdownSnippet) {
    if (!window.confirm(t("删除自定义片段“{name}”？", { name: snippetLabel(snippet) }))) return;
    const next = removeCustomMarkdownSnippet(scope, snippet.id);
    if (!persistCustomSnippets(scope, next)) {
      replaceCustomMarkdownSnippets(scope, customSnippets);
      setStatus("本地存储不可用，片段未删除。");
      return;
    }
    setCustomSnippets(next); onCustomSnippetsChange?.(next);
    if (editing?.id === snippet.id) { setFormOpen(false); setEditing(null); setDraft(emptyDraft()); }
    setStatus("自定义片段已删除。");
  }
  const customIds = new Set(customSnippets.map((snippet) => snippet.id));
  return <div ref={modalRoot} className="markdown-library-scrim" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="markdown-library-dialog" role="dialog" aria-modal="true" aria-labelledby="markdown-snippet-library-title">
      <header><div><h2 id="markdown-snippet-library-title">{t("Markdown 片段库")}</h2><p>{t("插入内置模板或此站点保存的自定义片段。")}</p></div><button className="markdown-library-close" type="button" onClick={onClose} aria-label={t("关闭片段库")}>×</button></header>
      <div className="markdown-library-content">
        <input ref={searchRef} className="markdown-library-search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder={t("搜索名称、快捷方式或内容")} aria-label={t("搜索 Markdown 片段")} />
        <div className="markdown-library-filter" aria-label={t("片段类别")}><button type="button" aria-pressed={filter === "all"} onClick={() => setFilter("all")}>{t("全部")}</button><button type="button" aria-pressed={filter === "template"} onClick={() => setFilter("template")}>{t("模板")}</button><button type="button" aria-pressed={filter === "snippet"} onClick={() => setFilter("snippet")}>{t("片段")}</button><button type="button" onClick={startCreate}>{t("新建自定义片段")}</button></div>
        <div className="markdown-library-list">{snippets.length ? snippets.map((snippet) => <article className="markdown-library-item" key={snippet.id}><div><h3>{displayLabel(snippet)}<span className="markdown-library-badge">{snippet.kind === "articleTemplate" ? t("模板") : t("片段")}</span>{customIds.has(snippet.id) && <span className="markdown-library-badge">{t("本网站")}</span>}</h3><p>{displayDescription(snippet) || t("快捷方式：/{shortcut}", { shortcut: snippet.shortcut })}</p><code>{snippetTemplate(snippet)}</code></div><div className="markdown-library-item-actions"><button type="button" disabled={disabled} onClick={() => insert(snippet)}>{t("插入")}</button>{customIds.has(snippet.id) && <><button type="button" onClick={() => startEdit(snippet)}>{t("编辑")}</button><button type="button" onClick={() => remove(snippet)}>{t("删除")}</button></>}</div></article>) : <p className="markdown-library-empty">{t("没有匹配的片段。")}</p>}</div>
        {formOpen && <div className="markdown-library-form"><h3>{editing ? t("编辑自定义片段") : t("新建自定义片段")}</h3><label>{t("名称")}<input maxLength={200} value={draft.label} onChange={(event) => updateDraft("label", event.target.value)} /></label><label>{t("快捷方式")}<input maxLength={80} value={draft.shortcut} onChange={(event) => updateDraft("shortcut", event.target.value)} placeholder={t("例如 note")} /></label><label>{t("说明（可选）")}<input maxLength={1000} value={draft.description} onChange={(event) => updateDraft("description", event.target.value)} /></label><label>{t("类别")}<select value={draft.kind} onChange={(event) => updateDraft("kind", event.target.value as MarkdownSnippetKind)}><option value="snippet">{t("片段")}</option><option value="articleTemplate">{t("模板")}</option></select></label><label>Markdown<textarea maxLength={100000} value={draft.template} onChange={(event) => updateDraft("template", event.target.value)} placeholder={t("可使用 {tokens}", { tokens: "{{title}}、{{slug}}、{{date}}" })} /></label><div className="markdown-library-actions"><button type="button" onClick={save}>{t("保存到此站点")}</button><button type="button" onClick={() => { setFormOpen(false); setEditing(null); setDraft(emptyDraft()); }}>{t("取消")}</button></div></div>}
        <p className="markdown-library-status" aria-live="polite">{t(status)}</p>
      </div>
    </section>
  </div>;
}

export { BUILT_IN_MARKDOWN_SNIPPETS };
