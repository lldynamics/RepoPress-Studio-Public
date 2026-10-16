import type { TextRange } from "./markdownWriting";
import { getMarkdownSections, type MarkdownSection } from "./markdownPowerTools";

/** Keep the outline responsive when a generated document contains thousands of headings. */
export const MARKDOWN_OUTLINE_MAX_ITEMS = 500;

export interface MarkdownOutlineItem extends MarkdownSection {
  id: string;
  hasChildren: boolean;
  activeTo: number;
}

export interface MarkdownOutlinePresentation {
  items: MarkdownOutlineItem[];
  totalCount: number;
  isPartial: boolean;
}

export function presentMarkdownOutline(value: string): MarkdownOutlinePresentation {
  const sections = getMarkdownSections(value);
  const items = sections.slice(0, MARKDOWN_OUTLINE_MAX_ITEMS).map((section, index, visible) => ({
    ...section,
    id: JSON.stringify([section.from, section.headingTo, section.level, section.title, index]),
    hasChildren: visible[index + 1]?.level > section.level,
    activeTo: sections[index + 1]?.from ?? value.length + 1,
  }));
  return { items, totalCount: sections.length, isPartial: sections.length > items.length };
}

export function activeMarkdownOutlineItemId(items: MarkdownOutlineItem[], selection: TextRange): string | null {
  const cursor = Math.max(0, Math.min(selection.from, selection.to));
  return items.find((item) => item.from <= cursor && cursor < item.activeTo)?.id ?? null;
}

export function visibleMarkdownOutlineItems(items: MarkdownOutlineItem[], collapsedItemIds: ReadonlySet<string>): MarkdownOutlineItem[] {
  let collapsedLevel: number | null = null;
  return items.filter((item) => {
    if (collapsedLevel !== null) {
      if (item.level > collapsedLevel) return false;
      collapsedLevel = null;
    }
    if (collapsedItemIds.has(item.id)) collapsedLevel = item.level;
    return true;
  });
}

export function markdownOutlineSignature(items: MarkdownOutlineItem[]): string {
  return items.map((item) => `${item.id}:${item.title}`).join("|");
}
