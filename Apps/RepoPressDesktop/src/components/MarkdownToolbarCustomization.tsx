import { useEffect, useId, useRef, useState } from "react";
import { DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS, MARKDOWN_FORMAT_COMMANDS, moveMarkdownToolbarItem, normalizeMarkdownToolbarItemIds, planMarkdownToolbarCustomizationItems, toggleMarkdownToolbarItem, type MarkdownToolbarItemId } from "../features/writing/markdownToolbarExperience";
import { useI18n } from "../i18n/i18n";
import { writingDialogsMessages } from "../i18n/writingDialogsMessages";

export interface MarkdownToolbarCustomizationProps {
  open: boolean;
  itemIds?: readonly MarkdownToolbarItemId[];
  onClose: () => void;
  onSave: (itemIds: MarkdownToolbarItemId[]) => Promise<void> | void;
}

export function MarkdownToolbarCustomization({ open, itemIds, onClose, onSave }: MarkdownToolbarCustomizationProps) {
  const { t } = useI18n(writingDialogsMessages);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const triggerRestoreFocusRef = useRef<HTMLElement | null>(null);
  const wasOpenRef = useRef(false);
  const closingFromPropRef = useRef(false);
  const [draft, setDraft] = useState<MarkdownToolbarItemId[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<{ message: string; controlled: boolean } | null>(null);
  const titleId = useId();
  const descriptionId = useId();

  function restoreTriggerFocus() {
    requestAnimationFrame(() => triggerRestoreFocusRef.current?.focus());
  }

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && !wasOpenRef.current) {
      setDraft(normalizeMarkdownToolbarItemIds(itemIds));
      setSaving(false);
      setError(null);
      triggerRestoreFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      if (!dialog.open) {
        if (typeof dialog.showModal === "function") dialog.showModal();
        else dialog.setAttribute("open", "");
      }
      requestAnimationFrame(() => { if (dialog.open) dialog.querySelector<HTMLElement>("input, button")?.focus(); });
    }
    if (!open && dialog.open) {
      closingFromPropRef.current = true;
      if (typeof dialog.close === "function") dialog.close();
      else dialog.removeAttribute("open");
      if (typeof dialog.close !== "function") {
        closingFromPropRef.current = false;
        restoreTriggerFocus();
      }
    }
    wasOpenRef.current = open;
  }, [open, itemIds]);

  function close() {
    if (saving) return;
    onClose();
  }

  function handleNativeClose() {
    const closingFromProp = closingFromPropRef.current;
    closingFromPropRef.current = false;
    wasOpenRef.current = false;
    if (!closingFromProp) onClose();
    restoreTriggerFocus();
  }

  async function save() {
    if (saving) return;
    setSaving(true);
    setError(null);
    try {
      await onSave(draft);
      onClose();
    } catch (reason) {
      setError(reason instanceof Error ? { message: reason.message, controlled: false } : { message: "保存工具栏配置失败，请重试。", controlled: true });
    } finally {
      setSaving(false);
    }
  }

  return <dialog ref={dialogRef} className="markdown-toolbar-customization" aria-labelledby={titleId} aria-describedby={descriptionId} onCancel={(event) => { event.preventDefault(); close(); }} onClose={handleNativeClose}>
    <header className="markdown-toolbar-customization__header">
      <div><h2 id={titleId}>{t("自定义格式工具栏")}</h2><p id={descriptionId}>{t("选择要显示的格式，并调整已启用格式的顺序。")}</p></div>
      <button type="button" onClick={close} disabled={saving} aria-label={t("关闭格式工具栏自定义")}>×</button>
    </header>
    <ul className="markdown-toolbar-customization__list" aria-label={t("格式工具栏项目")}>
      {planMarkdownToolbarCustomizationItems(draft).map((format) => {
        const command = MARKDOWN_FORMAT_COMMANDS.find((item) => item.format === format);
        if (!command) return null;
        const label = t(command.label);
        const index = draft.indexOf(format);
        const enabled = index >= 0;
        return <li key={format} className={enabled ? "is-enabled" : ""}>
          <label><input type="checkbox" checked={enabled} disabled={saving} onChange={() => setDraft((current) => toggleMarkdownToolbarItem(current, format))} />{label}</label>
          <div className="markdown-toolbar-customization__move" aria-label={t("{label} 排序", { label })}>
            <button type="button" disabled={saving || !enabled || index === 0} onClick={() => setDraft((current) => moveMarkdownToolbarItem(current, format, "up"))} aria-label={t("上移 {label}", { label })}>{t("上移")}</button>
            <button type="button" disabled={saving || !enabled || index === draft.length - 1} onClick={() => setDraft((current) => moveMarkdownToolbarItem(current, format, "down"))} aria-label={t("下移 {label}", { label })}>{t("下移")}</button>
          </div>
        </li>;
      })}
    </ul>
    {error && <p className="markdown-toolbar-customization__error" role="alert">{error.controlled ? t(error.message) : error.message}</p>}
    <footer className="markdown-toolbar-customization__footer">
      <button type="button" onClick={() => { setDraft([...DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS]); setError(null); }} disabled={saving}>{t("恢复默认")}</button>
      <span />
      <button type="button" onClick={close} disabled={saving}>{t("取消")}</button>
      <button type="button" className="primary" onClick={() => void save()} disabled={saving}>{t(saving ? "正在保存…" : "保存")}</button>
    </footer>
  </dialog>;
}
