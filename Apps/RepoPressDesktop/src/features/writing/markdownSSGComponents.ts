import { markdownFrontMatterBodyOffset, transitionMarkdownFence, type MarkdownFenceState } from "./markdownSyntaxContext";

export type MarkdownSSGComponentKind = "callout" | "lead" | "youtube" | "bilibili" | "githubCard" | "figure" | "custom";

export interface MarkdownSSGComponentOccurrence {
  id: string;
  kind: MarkdownSSGComponentKind;
  title: string;
  sourceRange: { from: number; to: number };
  source: string;
  previewText: string;
  lineNumber: number;
}

const directiveNames = new Set(["tip", "note", "info", "warning", "caution", "danger", "important"]);

const componentTitles: Record<MarkdownSSGComponentKind, string> = {
  callout: "提示框",
  lead: "导语",
  youtube: "YouTube 视频",
  bilibili: "B 站视频",
  githubCard: "GitHub 卡片",
  figure: "图片短代码",
  custom: "自定义短代码",
};

type PendingComponent = {
  kind: MarkdownSSGComponentKind;
  title: string;
  opening: "directive" | "hugo";
  hugoName?: string;
  from: number;
  contentFrom: number;
  lineNumber: number;
};

function compactPreview(value: string, fallback: string): string {
  const normalized = value.replace(/\r\n?/g, "\n").trim().split(/\s+/u).filter(Boolean).join(" ");
  if (!normalized) return fallback;
  return Array.from(normalized).slice(0, 96).join("");
}

function inlineKind(name: string): MarkdownSSGComponentKind {
  switch (name.toLowerCase()) {
    case "youtube": return "youtube";
    case "bilibili":
    case "bili": return "bilibili";
    case "github":
    case "github-card":
    case "githubcard": return "githubCard";
    case "figure": return "figure";
    default: return "custom";
  }
}

function pairedKind(name: string): MarkdownSSGComponentKind | null {
  switch (name.toLowerCase()) {
    case "lead": return "lead";
    case "callout":
    case "admonition": return "callout";
    default: return null;
  }
}

function makeOccurrence(
  pending: PendingComponent,
  source: string,
  to: number,
  contentTo: number,
): MarkdownSSGComponentOccurrence {
  const safeTo = Math.max(pending.from, Math.min(source.length, to));
  const safeContentTo = Math.max(pending.contentFrom, Math.min(safeTo, contentTo));
  const range = { from: pending.from, to: safeTo };
  return {
    id: `${pending.kind}-${pending.from}`,
    kind: pending.kind,
    title: pending.title,
    sourceRange: range,
    source: source.slice(range.from, range.to),
    previewText: compactPreview(source.slice(pending.contentFrom, safeContentTo), pending.title),
    lineNumber: pending.lineNumber,
  };
}

/**
 * Finds line-oriented SSG component syntax. Offsets intentionally use JS UTF-16
 * positions, the same coordinate system as CodeMirror selections.
 */
export function getMarkdownSSGComponentOccurrences(markdown: string): MarkdownSSGComponentOccurrence[] {
  const bodyOffset = markdownFrontMatterBodyOffset(markdown);
  if (!markdown || !Number.isFinite(bodyOffset)) return [];

  const occurrences: MarkdownSSGComponentOccurrence[] = [];
  let pending: PendingComponent | null = null;
  let fence: MarkdownFenceState = { marker: null, length: 0 };
  let offset = 0;
  let lineNumber = 1;

  while (offset < markdown.length) {
    const newline = markdown.indexOf("\n", offset);
    const lineContentEnd = newline < 0 ? markdown.length : newline;
    const lineEnd = newline < 0 ? markdown.length : newline + 1;
    const line = markdown.slice(offset, lineContentEnd).replace(/\r$/, "");

    if (offset >= bodyOffset) {
      const transition = transitionMarkdownFence(line, fence);
      if (fence.marker || transition.delimiterLine) {
        fence = transition.state;
      } else if (pending) {
        const trimmed = line.trim();
        const closesDirective = pending.opening === "directive" && trimmed === ":::";
        const hugoClosing = trimmed.match(/^\{\{<\s*\/\s*([A-Za-z0-9_-]+)\s*>\}\}$/);
        const closesHugo = pending.opening === "hugo" && hugoClosing?.[1]?.toLowerCase() === pending.hugoName;
        if (closesDirective || closesHugo) {
          occurrences.push(makeOccurrence(pending, markdown, lineEnd, offset));
          pending = null;
        }
      } else {
        const trimmed = line.trim();
        const directive = trimmed.match(/^:::\s*([A-Za-z0-9_-]+)(?:\s+(.*))?$/);
        if (directive && directiveNames.has(directive[1].toLowerCase())) {
          const title = directive[2]?.trim() || "提示";
          pending = { kind: "callout", title, opening: "directive", from: offset, contentFrom: lineEnd, lineNumber };
        } else {
          const hugo = trimmed.match(/^\{\{<\s*([A-Za-z0-9_-]+)(?:\s+([^>]*?))?\s*>\}\}$/);
          if (hugo) {
            const name = hugo[1].toLowerCase();
            const argument = hugo[2]?.trim() || "";
            const paired = pairedKind(name);
            if (paired) {
              pending = {
                kind: paired,
                title: argument || componentTitles[paired],
                opening: "hugo",
                hugoName: name,
                from: offset,
                contentFrom: lineEnd,
                lineNumber,
              };
            } else {
              const kind = inlineKind(name);
              const range = { from: offset, to: lineEnd };
              const title = componentTitles[kind];
              occurrences.push({
                id: `${kind}-${offset}`,
                kind,
                title,
                sourceRange: range,
                source: markdown.slice(range.from, range.to),
                previewText: compactPreview(argument, title),
                lineNumber,
              });
            }
          }
        }
      }
    }

    offset = lineEnd;
    lineNumber += 1;
  }

  if (pending) occurrences.push(makeOccurrence(pending, markdown, markdown.length, markdown.length));
  return occurrences.sort((left, right) => left.sourceRange.from - right.sourceRange.from);
}
