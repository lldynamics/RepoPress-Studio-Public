import type { TextEditResult, TextRange } from "../features/writing/markdownWriting";
import { getMarkdownTableEditingContext, planMarkdownTableEdit, type MarkdownTableEditingCommand } from "../features/writing/markdownTableEditing";
import { useI18n } from "../i18n/i18n";
import { editingMenuMessages } from "../i18n/editingMenuMessages";
import "./MarkdownTableEditingMenu.css";

export interface MarkdownTableEditingMenuProps { value: string; selection: TextRange; disabled?: boolean; onApply: (result: TextEditResult, status?: string) => void; }
const actions: Array<[MarkdownTableEditingCommand, string]> = [
  ["navigateForward", "下一个单元格"], ["navigateBackward", "上一个单元格"], ["format", "对齐表格"],
  ["insertRowAbove", "在上方插入行"], ["insertRowBelow", "在下方插入行"], ["deleteRow", "删除当前行"],
  ["insertColumnBefore", "在左侧插入列"], ["insertColumnAfter", "在右侧插入列"], ["deleteColumn", "删除当前列"],
];
function unavailable(command: MarkdownTableEditingCommand, context: ReturnType<typeof getMarkdownTableEditingContext>): boolean {
  return !context || (command === "deleteRow" && !context.canDeleteRow) || (command === "deleteColumn" && !context.canDeleteColumn);
}

export function MarkdownTableEditingMenu({ value, selection, disabled = false, onApply }: MarkdownTableEditingMenuProps) {
  const { t } = useI18n(editingMenuMessages);
  const context = getMarkdownTableEditingContext(value, selection);
  return <details className="markdown-table-editing-menu">
    <summary aria-label={t("打开 Markdown 表格编辑菜单")}>{t("表格")}</summary>
    <div className="markdown-table-editing-menu__items" role="toolbar" aria-label={t("Markdown 表格编辑")}>
      {actions.map(([command, title]) => { const translatedTitle = t(title); return <button key={command} type="button" disabled={disabled || unavailable(command, context)} title={translatedTitle} aria-label={translatedTitle} onClick={(event) => {
        const result = planMarkdownTableEdit(value, selection, command);
        if (result) { onApply(result, t("{action}完成", { action: translatedTitle })); event.currentTarget.closest("details")?.removeAttribute("open"); }
      }}>{translatedTitle}</button>; })}
    </div>
  </details>;
}
