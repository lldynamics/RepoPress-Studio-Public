import { useEffect, useId, useRef, useState } from "react";
import { filterMarkdownShortcuts, MARKDOWN_EDITOR_OPERATIONS } from "../features/writing/markdownToolbarExperience";
import { useI18n } from "../i18n/i18n";
import { writingDialogsMessages } from "../i18n/writingDialogsMessages";

export interface MarkdownShortcutHelpProps {
  disabled?: boolean;
}

export function MarkdownShortcutHelp({ disabled = false }: MarkdownShortcutHelpProps) {
  const { t } = useI18n(writingDialogsMessages);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const triggerRef = useRef<HTMLButtonElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const titleId = useId();

  function restoreTriggerFocus() {
    requestAnimationFrame(() => triggerRef.current?.focus());
  }

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && !dialog.open) {
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
    }
    if (!open && dialog.open) {
      if (typeof dialog.close === "function") dialog.close();
      else dialog.removeAttribute("open");
    }
    if (open) requestAnimationFrame(() => { if (dialog.open) inputRef.current?.focus(); });
  }, [open]);

  function close() { setOpen(false); setQuery(""); }

  function handleNativeClose() {
    setOpen(false);
    setQuery("");
    restoreTriggerFocus();
  }

  const shortcuts = filterMarkdownShortcuts(query);
  return <>
    <button ref={triggerRef} type="button" className="markdown-writing-toolbar__help" onClick={() => setOpen(true)} disabled={disabled} aria-haspopup="dialog" aria-expanded={open}>{t("快捷键")}</button>
    <dialog ref={dialogRef} className="markdown-shortcut-help" aria-labelledby={titleId} onCancel={(event) => { event.preventDefault(); close(); }} onClose={handleNativeClose}>
      <div className="markdown-shortcut-help__header"><h2 id={titleId}>{t("编辑器快捷键与操作")}</h2><button type="button" onClick={close} aria-label={t("关闭快捷键帮助")}>×</button></div>
      <label className="markdown-shortcut-help__search">{t("搜索快捷键")}<input ref={inputRef} value={query} onChange={(event) => setQuery(event.target.value)} placeholder={t("例如：表格、保存、Tab")} /></label>
      <ul className="markdown-shortcut-help__list">{shortcuts.map((item) => <li key={item.id}><div><strong>{t(item.label)}</strong><small>{t(item.detail)}</small></div><kbd>{item.shortcut}</kbd></li>)}{shortcuts.length === 0 && <li className="markdown-shortcut-help__empty">{t("没有匹配的快捷键。")}</li>}</ul>
      <h3 className="markdown-shortcut-help__section-title">{t("编辑器操作")}</h3>
      <ul className="markdown-shortcut-help__list">{MARKDOWN_EDITOR_OPERATIONS.filter((item) => !query || [item.label, item.detail, ...item.keywords].join(" ").normalize("NFKC").toLocaleLowerCase().includes(query.normalize("NFKC").trim().toLocaleLowerCase())).map((item) => <li key={item.id}><div><strong>{t(item.label)}</strong><small>{t(item.detail)}</small></div></li>)}</ul>
    </dialog>
  </>;
}
