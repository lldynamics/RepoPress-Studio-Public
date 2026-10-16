import type { TextRange, TextEditResult } from "./markdownWriting";
import { isInsideMarkdownFence, isInsideMarkdownInlineCode, markdownFrontMatterBodyOffset, transitionMarkdownFence, type MarkdownFenceState } from "./markdownSyntaxContext";

export interface SlashCommand { id: string; label: string; description: string; keywords: string[]; template: string; selectionToken?: string; caretOffset?: number }
export interface SlashQuery { from: number; to: number; query: string }
export interface SlashEditResult extends TextEditResult { triggerRange: TextRange; expectedText: string }

export const markdownSlashCommands: SlashCommand[] = [
  { id: "paragraph", label: "正文", description: "插入一段正文", keywords: ["正文", "段落", "text"], template: "" },
  { id: "heading-1", label: "一级标题", description: "插入 H1 标题", keywords: ["标题", "h1"], template: "# " },
  { id: "heading-2", label: "二级标题", description: "插入 H2 标题", keywords: ["标题", "h2"], template: "## " },
  { id: "heading-3", label: "三级标题", description: "插入 H3 标题", keywords: ["标题", "h3"], template: "### " },
  { id: "quote", label: "引用", description: "插入引用块", keywords: ["引用", "quote"], template: "> " },
  { id: "unordered-list", label: "无序列表", description: "插入无序列表", keywords: ["列表", "无序", "bullet"], template: "- " },
  { id: "ordered-list", label: "有序列表", description: "插入有序列表", keywords: ["列表", "有序", "number"], template: "1. " },
  { id: "task-list", label: "任务列表", description: "插入待办事项", keywords: ["任务", "待办", "todo"], template: "- [ ] " },
  { id: "code-block", label: "代码块", description: "插入 fenced code block", keywords: ["代码", "code"], template: "```\n\n```", caretOffset: 4 },
  { id: "table", label: "表格", description: "插入两列表格", keywords: ["表格", "table"], template: "| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |", selectionToken: "列 1" },
  { id: "image", label: "图片占位", description: "插入图片占位语法", keywords: ["图片", "图像", "image"], template: "![图片说明](images/)", selectionToken: "图片说明" },
  { id: "footnote", label: "脚注", description: "插入脚注引用与定义", keywords: ["脚注", "footnote", "注释"], template: "" },
  { id: "divider", label: "分隔线", description: "插入分隔线", keywords: ["分隔线", "横线", "hr"], template: "---" },
];

export function findSlashQuery(source: string, cursor: number): SlashQuery | null {
  const safe = Math.max(0, Math.min(source.length, cursor));
  const lineStart = source.lastIndexOf("\n", safe - 1) + 1;
  const bodyOffset = markdownFrontMatterBodyOffset(source);
  if (safe < bodyOffset) return null;
  const before = source.slice(lineStart, safe);
  if (isInsideMarkdownFence(source, lineStart, bodyOffset, before) || isInsideMarkdownInlineCode(before)) return null;
  const match = before.match(/^(\s*)\/([^\s]*)$/);
  return match ? { from: lineStart + match[1].length, to: safe, query: match[2] } : null;
}

export function getSlashCommands(query: string): SlashCommand[] {
  const normalized = normalizedSlashSearch(query.trim());
  if (!normalized) return markdownSlashCommands;
  return markdownSlashCommands.filter((command) => [command.label, command.description, ...command.keywords]
    .some((value) => normalizedSlashSearch(value).includes(normalized)));
}

function normalizedSlashSearch(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase();
}

export function applySlashCommand(source: string, cursor: number, id: string, expectedText?: string): SlashEditResult | null {
  const query = findSlashQuery(source, cursor);
  const command = markdownSlashCommands.find((item) => item.id === id);
  if (!query || !command) return null;
  if (expectedText !== undefined && source.slice(query.from, query.to) !== expectedText) return null;
  const footnote = nextFootnoteNumber(source);
  const value = id === "footnote" ? `[^${footnote}]\n\n[^${footnote}]: ` : command.template;
  const text = source.slice(0, query.from) + value + source.slice(query.to);
  let selection = { from: query.from + value.length, to: query.from + value.length };
  if (command.selectionToken) {
    const tokenStart = value.indexOf(command.selectionToken);
    if (tokenStart >= 0) selection = { from: query.from + tokenStart, to: query.from + tokenStart + command.selectionToken.length };
  } else if (command.caretOffset !== undefined) {
    selection = { from: query.from + command.caretOffset, to: query.from + command.caretOffset };
  }
  return { text, selection, triggerRange: { from: query.from, to: query.to }, expectedText: source.slice(query.from, query.to) };
}

function nextFootnoteNumber(source: string): number {
  const used = [...source.matchAll(/\[\^(\d+)\]/g)].map((match) => Number(match[1]));
  return used.length ? Math.max(...used) + 1 : 1;
}

export interface MarkdownSection { level: number; title: string; line: number; from: number; to: number; headingTo: number }

export function markdownAnchorSlug(title: string): string {
  return title.trim().toLocaleLowerCase().replace(/[`*_~]/g, "").replace(/[^\p{L}\p{N}\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul} -]/gu, "").replace(/\s+/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "section";
}

export function getMarkdownSectionAnchor(source: string, sectionIndex: number): string | null {
  const sections = getMarkdownSections(source); const section = sections[sectionIndex]; if (!section) return null;
  const base = markdownAnchorSlug(section.title); const prior = sections.slice(0, sectionIndex).filter((item) => markdownAnchorSlug(item.title) === base).length;
  return prior ? `${base}-${prior}` : base;
}

function contentLines(source: string): { lines: string[]; offsets: number[] } {
  const lines = source.split("\n"); const offsets: number[] = []; let offset = 0;
  for (const line of lines) { offsets.push(offset); offset += line.length + 1; }
  return { lines, offsets };
}

export function getMarkdownSections(source: string): MarkdownSection[] {
  const { lines, offsets } = contentLines(source); const sections: MarkdownSection[] = [];
  const bodyOffset = markdownFrontMatterBodyOffset(source);
  let fence: MarkdownFenceState = { marker: null, length: 0 };
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (offsets[index] < bodyOffset) continue;
    const wasFenced = Boolean(fence.marker); const transition = transitionMarkdownFence(line.replace(/\r$/, ""), fence); fence = transition.state;
    if (wasFenced || transition.delimiterLine) continue;
    const match = line.match(/^\s*(#{1,6})\s+(.+?)\s*#*\s*$/);
    if (match) {
      const title = match[2].trim(); const titleStart = line.indexOf(match[2]);
      sections.push({ level: match[1].length, title, line: index + 1, from: offsets[index], to: offsets[index] + line.length, headingTo: offsets[index] + titleStart + title.length });
    }
  }
  for (let index = 0; index < sections.length; index += 1) {
    const section = sections[index]; let end = source.length;
    for (let next = index + 1; next < sections.length; next += 1) if (sections[next].level <= section.level) { end = sections[next].from; break; }
    section.to = end;
  }
  return sections;
}

function sectionResult(source: string, from: number, to: number, replacement: string, cursor: number): TextEditResult {
  const text = source.slice(0, from) + replacement + source.slice(to); const mapped = Math.max(0, Math.min(text.length, cursor));
  return { text, selection: { from: mapped, to: mapped } };
}

export function moveMarkdownSection(source: string, sectionIndex: number, direction: "up" | "down"): TextEditResult | null {
  const sections = getMarkdownSections(source); const section = sections[sectionIndex]; if (!section) return null;
  const parent = sections.slice(0, sectionIndex).reverse().find((item) => item.level < section.level);
  const parentIndex = parent ? sections.indexOf(parent) : -1;
  const siblingParent = (item: MarkdownSection, index: number): number => {
    const nearest = sections.slice(0, index).reverse().find((candidate) => candidate.level < item.level);
    return nearest ? sections.indexOf(nearest) : -1;
  };
  const siblings = sections.filter((item, index) => item.level === section.level && siblingParent(item, index) === parentIndex); const siblingPosition = siblings.indexOf(section); const other = siblings[siblingPosition + (direction === "up" ? -1 : 1)];
  if (!other) return null;
  const first = Math.min(section.from, other.from); const last = Math.max(section.to, other.to); const a = source.slice(section.from, section.to); const b = source.slice(other.from, other.to);
  const gap = source.slice(Math.min(section.to, other.to), Math.max(section.from, other.from));
  const replacement = direction === "up" ? a + gap + b : b + gap + a;
  const movedSectionStart = direction === "up" ? first : first + b.length + gap.length;
  return sectionResult(source, first, last, replacement, movedSectionStart);
}

export function duplicateMarkdownSection(source: string, sectionIndex: number): TextEditResult | null {
  const section = getMarkdownSections(source)[sectionIndex]; if (!section) return null;
  const block = source.slice(section.from, section.to); const separator = block.endsWith("\n") ? "\n" : "\n\n"; const insertion = separator + block;
  return sectionResult(source, section.to, section.to, insertion, section.to + separator.length);
}

export function deleteMarkdownSection(source: string, sectionIndex: number): TextEditResult | null {
  const section = getMarkdownSections(source)[sectionIndex]; if (!section) return null;
  const from = section.from > 0 && source[section.from - 1] === "\n" ? section.from - 1 : section.from;
  const to = from === section.from && source[section.to] === "\n" ? section.to + 1 : section.to;
  return sectionResult(source, from, to, "", from);
}

export function applyMarkdownIndent(source: string, selection: TextRange, direction: "indent" | "outdent"): TextEditResult {
  const from = Math.max(0, Math.min(source.length, Math.min(selection.from, selection.to))); const to = Math.max(from, Math.min(source.length, Math.max(selection.from, selection.to)));
  const start = source.lastIndexOf("\n", Math.max(0, from - 1)) + 1;
  const lastSelected = to > from ? to - 1 : to;
  const endBreak = source.indexOf("\n", lastSelected); const end = endBreak < 0 ? source.length : endBreak;
  const lines = source.slice(start, end).split("\n");
  const nonEmptyLines = lines.filter((line) => line.trim());
  if (!nonEmptyLines.length || !nonEmptyLines.every((line) => /^\s*(?:(?:[-+*])(?:\s+|\s+\[[ xX]\]\s*)|\d+(?:[.)]\s+|、\s*)|>+\s+)/.test(line))) return { text: source, selection };
  const changes = lines.map((line) => {
    if (!line.trim()) return { output: line, removed: 0, added: 0 };
    if (direction === "indent") return { output: `  ${line}`, removed: 0, added: 2 };
    const prefix = line.match(/^(?: {1,2}|\t)/)?.[0] ?? "";
    return { output: line.slice(prefix.length), removed: prefix.length, added: 0 };
  });
  const output = changes.map((change) => change.output).join("\n");
  const delta = output.length - (end - start);
  const map = (at: number) => {
    if (at < start) return at;
    if (at >= end) return at + delta;
    let oldLineStart = start; let newLineStart = start;
    for (let index = 0; index < lines.length; index += 1) {
      const oldLineEnd = oldLineStart + lines[index].length;
      if (at <= oldLineEnd) return newLineStart + changes[index].added + Math.max(0, at - oldLineStart - changes[index].removed);
      oldLineStart = oldLineEnd + 1;
      newLineStart += changes[index].output.length + 1;
    }
    return start + output.length;
  };
  return { text: source.slice(0, start) + output + source.slice(end), selection: { from: map(selection.from), to: map(selection.to) } };
}
