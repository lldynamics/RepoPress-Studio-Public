import type { MarkdownFormat } from "./markdownWriting";

export interface MarkdownToolbarCommand { format: MarkdownFormat; label: string; hint: string }
export type MarkdownToolbarItemId = MarkdownFormat;
export const MARKDOWN_FORMAT_COMMANDS: readonly MarkdownToolbarCommand[] = [
  { format: "bold", label: "粗体", hint: "Ctrl/⌘ B" }, { format: "italic", label: "斜体", hint: "Ctrl/⌘ I" }, { format: "strike", label: "删除线", hint: "" }, { format: "code", label: "行内代码", hint: "" }, { format: "link", label: "链接", hint: "" },
  { format: "heading", label: "标题", hint: "" }, { format: "quote", label: "引用", hint: "" }, { format: "unorderedList", label: "无序列表", hint: "" }, { format: "orderedList", label: "有序列表", hint: "" }, { format: "taskList", label: "任务列表", hint: "" },
  { format: "codeBlock", label: "代码块", hint: "" }, { format: "horizontalRule", label: "分隔线", hint: "" },
];
export const DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS: readonly MarkdownToolbarItemId[] = MARKDOWN_FORMAT_COMMANDS.map((command) => command.format);
const BASIC_FORMATS: readonly MarkdownToolbarItemId[] = ["heading", "bold", "italic", "unorderedList", "link"];
const MARKDOWN_TOOLBAR_ITEM_IDS = new Set<MarkdownToolbarItemId>(DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS);

/**
 * A missing preference means the default toolbar. An explicit empty preference
 * is meaningful: it hides every format command.
 */
export function normalizeMarkdownToolbarItemIds(itemIds?: readonly string[] | null): MarkdownToolbarItemId[] {
  if (itemIds === undefined || itemIds === null) return [...DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS];
  const seen = new Set<MarkdownToolbarItemId>();
  return itemIds.filter((item): item is MarkdownToolbarItemId => {
    if (!MARKDOWN_TOOLBAR_ITEM_IDS.has(item as MarkdownToolbarItemId) || seen.has(item as MarkdownToolbarItemId)) return false;
    seen.add(item as MarkdownToolbarItemId);
    return true;
  });
}

export function toggleMarkdownToolbarItem(itemIds: readonly MarkdownToolbarItemId[], itemId: MarkdownToolbarItemId): MarkdownToolbarItemId[] {
  const normalized = normalizeMarkdownToolbarItemIds(itemIds);
  return normalized.includes(itemId) ? normalized.filter((item) => item !== itemId) : [...normalized, itemId];
}

export function moveMarkdownToolbarItem(itemIds: readonly MarkdownToolbarItemId[], itemId: MarkdownToolbarItemId, direction: "up" | "down"): MarkdownToolbarItemId[] {
  const normalized = normalizeMarkdownToolbarItemIds(itemIds);
  const index = normalized.indexOf(itemId);
  const destination = index + (direction === "up" ? -1 : 1);
  if (index < 0 || destination < 0 || destination >= normalized.length) return normalized;
  const next = [...normalized];
  [next[index], next[destination]] = [next[destination], next[index]];
  return next;
}

export interface MarkdownToolbarFormatPlan {
  direct: MarkdownToolbarItemId[];
  more: MarkdownToolbarItemId[];
}

export type MarkdownToolbarMenu = "insert" | "format";

export interface MarkdownToolbarResponsivePlan extends MarkdownToolbarFormatPlan {
  /** Overflow commands grouped for the two compact menus. */
  insert: MarkdownToolbarItemId[];
  format: MarkdownToolbarItemId[];
}

const FREQUENT_FORMATS: readonly MarkdownToolbarItemId[] = ["heading", "bold", "italic", "unorderedList", "link"];
const INSERT_FORMATS: readonly MarkdownToolbarItemId[] = ["link", "codeBlock", "horizontalRule"];

/**
 * Plans the current Mac-like toolbar surface. Width is a measured container
 * width, rather than a viewport width; an absent or invalid measurement uses
 * a conservative default so every enabled command remains reachable.
 */
export function planMarkdownToolbarResponsiveLayout(
  density: "basic" | "professional" = "basic",
  itemIds?: readonly MarkdownToolbarItemId[] | null,
  width?: number,
): MarkdownToolbarResponsivePlan {
  const enabled = normalizeMarkdownToolbarItemIds(itemIds);
  const candidates = density === "professional"
    ? enabled
    : [...FREQUENT_FORMATS.filter((item) => enabled.includes(item)), ...enabled.filter((item) => !FREQUENT_FORMATS.includes(item))];
  const measuredWidth = Number.isFinite(width) && (width ?? 0) > 0 ? width as number : 640;
  // Reserve room for the two menus and toolbar options. Each direct command
  // is intentionally budgeted generously for translated labels.
  const capacity = Math.max(1, Math.floor((measuredWidth - 220) / 78));
  const direct = candidates.slice(0, Math.min(candidates.length, capacity));
  const more = candidates.filter((item) => !direct.includes(item));
  return {
    direct,
    more,
    insert: more.filter((item) => INSERT_FORMATS.includes(item)),
    format: more.filter((item) => !INSERT_FORMATS.includes(item)),
  };
}

/** Enabled items follow their draft order; hidden items remain catalog-ordered. */
export function planMarkdownToolbarCustomizationItems(itemIds?: readonly MarkdownToolbarItemId[] | null): MarkdownToolbarItemId[] {
  const enabled = normalizeMarkdownToolbarItemIds(itemIds);
  return [...enabled, ...DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS.filter((item) => !enabled.includes(item))];
}

export function planMarkdownToolbarFormatLayout(density: "basic" | "professional" = "basic", itemIds?: readonly MarkdownToolbarItemId[] | null): MarkdownToolbarFormatPlan {
  const enabled = normalizeMarkdownToolbarItemIds(itemIds);
  if (density === "professional") return { direct: enabled, more: [] };
  const isDefault = enabled.length === DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS.length
    && enabled.every((item, index) => item === DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS[index]);
  return {
    // Retain the established compact default even after it has been persisted,
    // while a real customization keeps the writer's direct-command order.
    direct: isDefault
      ? [...BASIC_FORMATS]
      : enabled.filter((item) => BASIC_FORMATS.includes(item)),
    more: enabled.filter((item) => !BASIC_FORMATS.includes(item)),
  };
}

export function planMarkdownToolbarFormats(density: "basic" | "professional" = "basic", itemIds?: readonly MarkdownToolbarItemId[] | null): MarkdownToolbarItemId[] {
  return planMarkdownToolbarFormatLayout(density, itemIds).direct;
}

export interface MarkdownShortcut {
  id: string;
  label: string;
  shortcut: string;
  detail: string;
  keywords: string[];
}

// Keep this catalog deliberately aligned with App.tsx and the editor's existing
// key handlers. Entries without a real key binding do not belong here.
export const MARKDOWN_SHORTCUT_CATALOG: readonly MarkdownShortcut[] = [
  { id: "save", label: "保存文稿", shortcut: "Ctrl/⌘ S", detail: "保存当前文稿", keywords: ["保存", "save"] },
  { id: "open-repository", label: "打开仓库", shortcut: "Ctrl/⌘ O", detail: "选择并打开本地仓库", keywords: ["仓库", "打开", "repository", "open"] },
  { id: "new-draft", label: "新建文稿", shortcut: "Ctrl/⌘ N", detail: "打开新建文稿对话框", keywords: ["新建", "文稿", "new"] },
  { id: "find", label: "查找文稿内容", shortcut: "Ctrl/⌘ F", detail: "打开写作面板并聚焦查找", keywords: ["查找", "find", "搜索"] },
  { id: "repository-search", label: "搜索仓库文件", shortcut: "Ctrl/⌘ Shift F", detail: "聚焦仓库文件搜索", keywords: ["仓库", "搜索", "repository", "search"] },
  { id: "editor-focus", label: "聚焦编辑器", shortcut: "Ctrl/⌘ Shift E", detail: "将焦点移到 Markdown 编辑器", keywords: ["编辑器", "焦点", "editor", "focus"] },
  { id: "go-to-line", label: "跳转到行", shortcut: "Ctrl/⌘ L", detail: "打开跳转到指定行", keywords: ["跳转", "行", "line", "go"] },
  { id: "publish", label: "打开发布中心", shortcut: "Ctrl/⌘ Shift P", detail: "打开发布工作区", keywords: ["发布", "publish"] },
  { id: "command-palette", label: "命令面板", shortcut: "Ctrl/⌘ K", detail: "打开命令面板", keywords: ["命令", "command", "palette"] },
  { id: "bold", label: "粗体", shortcut: "Ctrl/⌘ B", detail: "切换选中文本粗体", keywords: ["粗体", "bold"] },
  { id: "italic", label: "斜体", shortcut: "Ctrl/⌘ I", detail: "切换选中文本斜体", keywords: ["斜体", "italic"] },
  { id: "slash-menu", label: "斜杠菜单", shortcut: "/", detail: "在编辑器行首输入 / 打开插入菜单", keywords: ["斜杠", "slash", "插入"] },
  { id: "table-forward", label: "表格下一单元格", shortcut: "Tab", detail: "在 Markdown 表格中向前移动", keywords: ["表格", "table", "tab", "下一格"] },
  { id: "table-backward", label: "表格上一单元格", shortcut: "Shift Tab", detail: "在 Markdown 表格中向后移动", keywords: ["表格", "table", "shift", "tab", "上一格"] },
];

export interface MarkdownEditorOperation { id: string; label: string; detail: string; keywords: string[] }
export const MARKDOWN_EDITOR_OPERATIONS: readonly MarkdownEditorOperation[] = [
  { id: "fence-navigation", label: "代码围栏导航", detail: "使用编辑器中的按钮跳到开头、结尾或对应端", keywords: ["代码围栏", "fence", "导航"] },
];

export function filterMarkdownShortcuts(query: string, catalog: readonly MarkdownShortcut[] = MARKDOWN_SHORTCUT_CATALOG): MarkdownShortcut[] {
  const normalized = query.normalize("NFKC").trim().toLocaleLowerCase();
  if (!normalized) return [...catalog];
  return catalog.filter((item) => [item.label, item.shortcut, item.detail, ...item.keywords]
    .join(" ").normalize("NFKC").toLocaleLowerCase().includes(normalized));
}
