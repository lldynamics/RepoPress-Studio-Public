import { useEffect, useRef, useState, type ReactNode } from "react";
import type { MarkdownFormat, TextRange } from "../features/writing/markdownWriting";
import { DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS, MARKDOWN_FORMAT_COMMANDS, normalizeMarkdownToolbarItemIds, planMarkdownToolbarResponsiveLayout, type MarkdownToolbarItemId } from "../features/writing/markdownToolbarExperience";
import { MarkdownShortcutHelp } from "./MarkdownShortcutHelp";
import { MarkdownToolbarCustomization } from "./MarkdownToolbarCustomization";
import { useI18n } from "../i18n/i18n";
import "./MarkdownWritingTools.css";

export type MarkdownToolbarDensity = "basic" | "professional";

export interface MarkdownWritingToolbarProps {
  value: string;
  selection: TextRange;
  onFormat: (format: MarkdownFormat) => void;
  disabled?: boolean;
  className?: string;
  density?: MarkdownToolbarDensity;
  onDensityChange?: (density: MarkdownToolbarDensity) => void;
  /** Undefined uses the default layout; an empty array intentionally hides every format. */
  itemIds?: readonly MarkdownToolbarItemId[];
  onItemIdsChange?: (ids: MarkdownToolbarItemId[]) => Promise<void> | void;
}

interface ToolbarMenuProps { label: string; children: ReactNode; className?: string; menuId: string; openMenu: string | null; onOpenChange: (menuId: string | null) => void }

function ToolbarMenu({ label, children, className = "", menuId, openMenu, onOpenChange }: ToolbarMenuProps) {
  const detailsRef = useRef<HTMLDetailsElement>(null);
  const summaryRef = useRef<HTMLElement>(null);
  const isOpen = openMenu === menuId;
  function close() {
    const details = detailsRef.current;
    if (!details) return;
    details.removeAttribute("open");
    onOpenChange(null);
  }
  return <details ref={detailsRef} open={isOpen} className={`markdown-writing-toolbar__menu ${className}`.trim()} onToggle={(event) => {
    onOpenChange(event.currentTarget.open ? menuId : null);
  }} onKeyDown={(event) => {
    if (event.key !== "Escape") return;
    if (!event.currentTarget.open) return;
    event.preventDefault();
    event.stopPropagation();
    close();
    const restore = () => summaryRef.current?.focus();
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(restore);
    else restore();
  }}>
    <summary ref={summaryRef}>{label}</summary>
    <div className="markdown-writing-toolbar__menu-items" onClick={(event) => {
      if ((event.target as HTMLElement).closest("button")) close();
    }}>{children}</div>
  </details>;
}

export function MarkdownWritingToolbar({ value, selection, onFormat, disabled = false, className = "", density, onDensityChange, itemIds, onItemIdsChange }: MarkdownWritingToolbarProps) {
  const { t } = useI18n();
  const toolbarRef = useRef<HTMLDivElement>(null);
  const [containerWidth, setContainerWidth] = useState<number>();
  const [openMenu, setOpenMenu] = useState<string | null>(null);
  const [internalDensity, setInternalDensity] = useState<MarkdownToolbarDensity>("basic");
  const [internalItemIds, setInternalItemIds] = useState<MarkdownToolbarItemId[]>([...DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS]);
  const [hasInternalItemIds, setHasInternalItemIds] = useState(false);
  const [customizationOpen, setCustomizationOpen] = useState(false);
  const activeDensity = density ?? internalDensity;
  const activeItemIds = normalizeMarkdownToolbarItemIds(itemIds === undefined ? internalItemIds : itemIds);
  useEffect(() => {
    const element = toolbarRef.current;
    if (!element || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (entry) setContainerWidth(entry.contentRect.width);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  const plan = planMarkdownToolbarResponsiveLayout(activeDensity, itemIds === undefined && !hasInternalItemIds ? undefined : activeItemIds, containerWidth);
  const commandById = new Map(MARKDOWN_FORMAT_COMMANDS.map((command) => [command.format, command]));
  const directCommands = plan.direct.map((itemId) => commandById.get(itemId)).filter((command): command is (typeof MARKDOWN_FORMAT_COMMANDS)[number] => Boolean(command));
  const insertCommands = plan.insert.map((itemId) => commandById.get(itemId)).filter((command): command is (typeof MARKDOWN_FORMAT_COMMANDS)[number] => Boolean(command));
  const formatCommands = plan.format.map((itemId) => commandById.get(itemId)).filter((command): command is (typeof MARKDOWN_FORMAT_COMMANDS)[number] => Boolean(command));
  function changeDensity(next: MarkdownToolbarDensity) {
    setInternalDensity(next);
    onDensityChange?.(next);
  }
  async function saveItemIds(next: MarkdownToolbarItemId[]) {
    await onItemIdsChange?.(next);
    if (itemIds === undefined) {
      setInternalItemIds(next);
      setHasInternalItemIds(true);
    }
  }
  const renderCommand = ({ format, label, hint }: (typeof MARKDOWN_FORMAT_COMMANDS)[number]) => {
    const translatedLabel = t(label);
    return <button type="button" className="markdown-writing-toolbar__button" key={format} onClick={() => onFormat(format)} disabled={disabled} title={hint ? t("{label}（{hint}）", { label: translatedLabel, hint }) : translatedLabel} aria-label={translatedLabel}>{translatedLabel}</button>;
  };
  return <div ref={toolbarRef} className={`markdown-writing-toolbar ${className}`.trim()} role="toolbar" aria-label={t("Markdown 写作工具")} data-selection={`${selection.from}:${selection.to}`} data-content-length={value.length}>
    {directCommands.length > 0 && <div className="markdown-writing-toolbar__group" role="group" aria-label={t("常用 Markdown 格式")}>
      {directCommands.map(renderCommand)}
    </div>}
    {insertCommands.length > 0 && <ToolbarMenu menuId="insert" openMenu={openMenu} onOpenChange={setOpenMenu} label={t("插入")}><div role="group" aria-label={t("插入 Markdown 格式")}>{insertCommands.map(renderCommand)}</div></ToolbarMenu>}
    {formatCommands.length > 0 && <ToolbarMenu menuId="format" openMenu={openMenu} onOpenChange={setOpenMenu} label={t("格式")}><div role="group" aria-label={t("更多 Markdown 格式")}>{formatCommands.map(renderCommand)}</div></ToolbarMenu>}
    <ToolbarMenu menuId="options" openMenu={openMenu} onOpenChange={setOpenMenu} label={t("工具栏选项")} className="markdown-writing-toolbar__options">
      <div className="markdown-writing-toolbar__density" role="group" aria-label={t("工具密度")}>
        <button type="button" className={`markdown-writing-toolbar__density-button${activeDensity === "basic" ? " is-active" : ""}`} onClick={() => changeDensity("basic")} aria-pressed={activeDensity === "basic"}>{t("基础")}</button>
        <button type="button" className={`markdown-writing-toolbar__density-button${activeDensity === "professional" ? " is-active" : ""}`} onClick={() => changeDensity("professional")} aria-pressed={activeDensity === "professional"}>{t("专业")}</button>
      </div>
      <button type="button" className="markdown-writing-toolbar__customize" onClick={() => setCustomizationOpen(true)} aria-haspopup="dialog" aria-expanded={customizationOpen}>{t("自定义格式")}</button>
      <MarkdownShortcutHelp disabled={disabled} />
    </ToolbarMenu>
    <MarkdownToolbarCustomization open={customizationOpen} itemIds={activeItemIds} onClose={() => setCustomizationOpen(false)} onSave={saveItemIds} />
  </div>;
}
