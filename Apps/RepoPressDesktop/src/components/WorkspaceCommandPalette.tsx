import { useI18n } from "../i18n/i18n";
import { useEffect, useMemo, useRef, useState } from "react";
import type { MarkdownFileEntry } from "../contracts/repository";

export interface WorkspaceCommand {
  id: string;
  title: string;
  detail: string;
  shortcut?: string;
  disabled?: boolean;
  action: () => void;
}

interface WorkspaceCommandPaletteProps {
  open: boolean;
  files: MarkdownFileEntry[];
  selectedPath?: string;
  commands: WorkspaceCommand[];
  onClose: () => void;
  onOpenFile: (file: MarkdownFileEntry) => void;
}

type PaletteItem =
  | { id: string; kind: "command"; title: string; detail: string; shortcut?: string; disabled?: boolean; action: () => void }
  | { id: string; kind: "file"; title: string; detail: string; active: boolean; action: () => void };

/**
 * A local-only command surface: file matching uses the already enumerated
 * repository list, so opening it neither reads new files nor contacts a service.
 */
export function WorkspaceCommandPalette({ open, files, selectedPath, commands, onClose, onOpenFile }: WorkspaceCommandPaletteProps) {
  const { t } = useI18n();
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const input = useRef<HTMLInputElement>(null);

  const items = useMemo<PaletteItem[]>(() => {
    const normalized = query.trim().toLocaleLowerCase();
    const includes = (value: string) => !normalized || value.toLocaleLowerCase().includes(normalized);
    const commandItems = commands.filter((command) => includes(`${command.title} ${command.detail}`)).map((command) => ({ ...command, kind: "command" as const }));
    const fileItems = files.filter((file) => includes(`${file.relativePath} ${file.displayName} ${file.directory}`)).slice(0, 12).map((file) => ({
      id: `file:${file.relativePath}`,
      kind: "file" as const,
      title: file.displayName,
      detail: file.relativePath,
      active: file.relativePath === selectedPath,
      action: () => onOpenFile(file),
    }));
    return [...commandItems, ...fileItems];
  }, [commands, files, onOpenFile, query, selectedPath]);

  useEffect(() => {
    if (!open) return;
    setQuery("");
    setSelectedIndex(0);
    queueMicrotask(() => input.current?.focus());
  }, [open]);

  useEffect(() => setSelectedIndex((current) => Math.min(Math.max(0, current), Math.max(0, items.length - 1))), [items.length]);

  if (!open) return null;

  function activate(item = items[selectedIndex]) {
    if (!item || (item.kind === "command" && item.disabled)) return;
    onClose();
    item.action();
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLElement>) {
    if (event.key === "Escape") { event.preventDefault(); onClose(); return; }
    if (event.key === "ArrowDown") { event.preventDefault(); setSelectedIndex((current) => Math.min(items.length - 1, current + 1)); return; }
    if (event.key === "ArrowUp") { event.preventDefault(); setSelectedIndex((current) => Math.max(0, current - 1)); return; }
    if (event.key === "Home") { event.preventDefault(); setSelectedIndex(0); return; }
    if (event.key === "End") { event.preventDefault(); setSelectedIndex(Math.max(0, items.length - 1)); return; }
    if (event.key === "Enter") { event.preventDefault(); activate(); }
  }

  const commandItems = items.filter((item) => item.kind === "command");
  const fileItems = items.filter((item) => item.kind === "file");
  let index = -1;
  const row = (item: PaletteItem) => {
    index += 1;
    const rowIndex = index;
    const selected = selectedIndex === rowIndex;
    const disabled = item.kind === "command" && item.disabled;
    return <button id={item.id} role="option" aria-selected={selected} key={item.id} type="button" className={`command-palette-row${selected ? " selected" : ""}${item.kind === "file" && item.active ? " active" : ""}`} aria-current={item.kind === "file" && item.active ? "page" : undefined} disabled={disabled} onMouseMove={() => setSelectedIndex(rowIndex)} onClick={() => activate(item)}>
      <span className="command-palette-icon" aria-hidden="true">{item.kind === "file" ? "#" : "⌘"}</span>
      <span className="command-palette-label"><strong>{item.title}</strong><small>{item.detail}</small></span>
      {item.kind === "command" && item.shortcut && <kbd>{item.shortcut}</kbd>}
    </button>;
  };

  return <div className="command-palette-scrim" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="command-palette" role="dialog" aria-modal="true" aria-label={t("工作区命令面板")} onKeyDown={onKeyDown}>
      <label className="command-palette-search"><span aria-hidden="true">⌕</span><input ref={input} value={query} onChange={(event) => { setQuery(event.target.value); setSelectedIndex(0); }} placeholder={t("搜索命令、设置或 Markdown 文件")} aria-label={t("搜索命令和 Markdown 文件")} autoComplete="off" /><kbd>Esc</kbd></label>
      <div className="command-palette-results" role="listbox" aria-label={t("命令面板结果")} aria-activedescendant={items[selectedIndex]?.id}>
        {commandItems.length > 0 && <section><h2>{t("命令")}</h2>{commandItems.map(row)}</section>}
        {fileItems.length > 0 && <section><h2>{t("Markdown 文件")}</h2>{fileItems.map(row)}</section>}
        {!items.length && <p className="command-palette-empty">{t("没有匹配的命令或已列出的 Markdown 文件。")}</p>}
      </div>
      <footer><span><kbd>↑↓</kbd>{t(" 选择")}</span><span><kbd>Enter</kbd>{t(" 打开")}</span><span>{t("仅搜索当前已打开仓库的文件")}</span></footer>
    </section>
  </div>;
}
