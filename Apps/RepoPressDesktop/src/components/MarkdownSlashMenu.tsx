import { useEffect, useRef, useState } from "react";
import { getSlashCommands, markdownSlashCommands, type SlashCommand } from "../features/writing/markdownPowerTools";
import { BUILT_IN_MARKDOWN_SNIPPETS } from "../features/writing/markdownSnippets";
import { useI18n } from "../i18n/i18n";
import { slashMenuMessages } from "../i18n/slashMenuMessages";
import "./MarkdownPowerTools.css";

export interface MarkdownSlashMenuProps { query: string; open: boolean; commands?: SlashCommand[]; onSelect: (command: SlashCommand) => void; onClose: () => void; autoFocus?: boolean; builtinSnippetCommandIds?: readonly string[] }
export function MarkdownSlashMenu({ query, open, commands: providedCommands, onSelect, onClose, autoFocus = false, builtinSnippetCommandIds = [] }: MarkdownSlashMenuProps) {
  const { t } = useI18n(slashMenuMessages);
  const commands = providedCommands ?? getSlashCommands(query);
  const first = useRef<HTMLButtonElement>(null);
  const [activeIndex, setActiveIndex] = useState(0);
  useEffect(() => { setActiveIndex(0); if (open && autoFocus) first.current?.focus(); }, [open, query, autoFocus]);
  if (!open) return null;
  const displayCommand = (command: SlashCommand): { label: string; description: string } => {
    if (markdownSlashCommands.includes(command)) return { label: t(command.label), description: t(command.description) };
    if (command.id.startsWith("snippet:") && builtinSnippetCommandIds.includes(command.id)) {
      const builtin = BUILT_IN_MARKDOWN_SNIPPETS.find((item) => `snippet:${item.id}` === command.id);
      if (builtin && command.label === builtin.label && command.description === (builtin.description ?? "")) {
        return { label: t(builtin.label), description: t(builtin.description ?? "") };
      }
    }
    return { label: command.label, description: command.description };
  };
  function handleKeyDown(event: React.KeyboardEvent<HTMLButtonElement>, index: number): void {
    if (event.key === "Escape") { event.preventDefault(); onClose(); return; }
    if (!commands.length) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault(); const step = event.key === "ArrowDown" ? 1 : -1; const next = (index + step + commands.length) % commands.length; setActiveIndex(next);
      document.getElementById(`markdown-slash-command-${commands[next].id}`)?.focus();
    } else if (event.key === "Enter") { event.preventDefault(); onSelect(commands[index]); }
  }
  return <div className="markdown-slash-menu" role="listbox" aria-label={t("斜杠命令")} aria-live="polite"><div className="markdown-slash-menu__title">{t("插入块")}</div>{commands.length ? commands.map((command, index) => { const display = displayCommand(command); return <button ref={index === 0 ? first : undefined} id={`markdown-slash-command-${command.id}`} key={command.id} type="button" role="option" aria-selected={activeIndex === index} tabIndex={activeIndex === index ? 0 : -1} onFocus={() => setActiveIndex(index)} onClick={() => onSelect(command)} onKeyDown={(event) => handleKeyDown(event, index)}><strong>{display.label}</strong><span>{display.description}</span></button>; }) : <p>{t("没有匹配的命令")}</p>}</div>;
}
