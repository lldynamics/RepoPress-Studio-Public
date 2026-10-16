import type { TextRange } from "../features/writing/markdownWriting";
import { planMarkdownLineEdit, type MarkdownLineEditingCommand } from "../features/writing/markdownAdvancedEditing";
import { useI18n } from "../i18n/i18n";
import { editingMenuMessages } from "../i18n/editingMenuMessages";
import "./MarkdownAdvancedEditingMenu.css";

export interface MarkdownAdvancedEditingMenuProps { value: string; selection: TextRange; disabled?: boolean; onApply: (result: NonNullable<ReturnType<typeof planMarkdownLineEdit>>, status?: string) => void; }
const actions: Array<[MarkdownLineEditingCommand, string, string]> = [["moveUp", "↑", "上移行"], ["moveDown", "↓", "下移行"], ["duplicateAbove", "⇧", "向上复制行"], ["duplicateBelow", "⇩", "向下复制行"], ["toggleTaskCompletion", "☑", "切换任务完成状态"], ["deleteLine", "×", "删除行"], ["toggleComment", "⌘", "切换行注释"], ["removeFormatting", "Tx", "移除行格式"]];
export function MarkdownAdvancedEditingMenu({ value, selection, disabled = false, onApply }: MarkdownAdvancedEditingMenuProps) {
  const { t } = useI18n(editingMenuMessages);
  return <details className="markdown-advanced-editing-menu"><summary aria-label={t("打开 Markdown 行编辑菜单")}>{t("行编辑")}</summary><div className="markdown-advanced-editing-menu__items" role="toolbar" aria-label={t("Markdown 行编辑")}>{actions.map(([command, label, title]) => { const translatedTitle = t(title); return <button key={command} type="button" disabled={disabled} title={translatedTitle} aria-label={translatedTitle} onClick={(event) => { const result = planMarkdownLineEdit(value, selection, command); if (result) { onApply(result, t("{action}完成", { action: translatedTitle })); event.currentTarget.closest("details")?.removeAttribute("open"); } }}>{label} <span>{translatedTitle}</span></button>; })}</div></details>;
}
