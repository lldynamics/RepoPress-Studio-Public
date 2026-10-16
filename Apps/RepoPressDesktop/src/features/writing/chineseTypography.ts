import type { TextEditResult, TextRange } from "./markdownWriting";

/** A planned Chinese typography edit. `null` means the requested scope is already clean. */
export type ChineseTypographyPlan = TextEditResult | null;

const cjk = "\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff\\u3040-\\u30ff\\uac00-\\ud7af";
const punctuation = "，。！？；：、（）《》【】「」『』“”‘’";

function normalizedRange(source: string, selection: TextRange): TextRange {
  const first = Math.max(0, Math.min(source.length, selection.from));
  const second = Math.max(0, Math.min(source.length, selection.to));
  return { from: Math.min(first, second), to: Math.max(first, second) };
}

function uniquePlaceholder(source: string, index: number, protectedText: Map<string, string>): string {
  let nonce = 0;
  let placeholder = "";
  do {
    placeholder = `\uE000repo-press-chinese-typography-${index}-${nonce}\uE001`;
    nonce += 1;
  } while (source.includes(placeholder) || [...protectedText.values()].some((value) => value.includes(placeholder)));
  return placeholder;
}

function protectMatches(source: string, pattern: RegExp, protectedText: Map<string, string>): string {
  return source.replace(pattern, (match) => {
    const placeholder = uniquePlaceholder(source, protectedText.size, protectedText);
    protectedText.set(placeholder, match);
    return placeholder;
  });
}

function protectFrontMatter(source: string, protectedText: Map<string, string>): string {
  const opening = source.match(/^(---|\+\+\+)[ \t]*(?:\r\n|\n|\r)/)?.[1];
  if (!opening) return source;

  const boundary = opening === "---" ? /^(?:---|\.\.\.)[ \t]*$/ : /^\+\+\+[ \t]*$/;
  let cursor = source.indexOf("\n") + 1;
  while (cursor > 0 && cursor <= source.length) {
    const next = source.indexOf("\n", cursor);
    const lineEnd = next < 0 ? source.length : next;
    if (boundary.test(source.slice(cursor, lineEnd).replace(/\r$/, ""))) {
      const end = next < 0 ? source.length : next + 1;
      const placeholder = uniquePlaceholder(source, protectedText.size, protectedText);
      protectedText.set(placeholder, source.slice(0, end));
      return placeholder + source.slice(end);
    }
    if (next < 0) break;
    cursor = next + 1;
  }
  // An unfinished opening delimiter is more safely treated as front matter than prose.
  const placeholder = uniquePlaceholder(source, protectedText.size, protectedText);
  protectedText.set(placeholder, source);
  return placeholder;
}

function protectFencedCodeBlocks(source: string, protectedText: Map<string, string>): string {
  const lines: Array<{ from: number; to: number; content: string }> = [];
  for (let from = 0; from < source.length;) {
    const newline = source.indexOf("\n", from);
    const to = newline < 0 ? source.length : newline + 1;
    lines.push({ from, to, content: source.slice(from, newline < 0 ? source.length : newline).replace(/\r$/, "") });
    from = to;
  }

  let output = "";
  let copiedUntil = 0;
  for (let index = 0; index < lines.length; index += 1) {
    const opening = lines[index].content.match(/^ {0,3}(`{3,}|~{3,})[^\r\n]*$/)?.[1];
    if (!opening) continue;
    const marker = opening[0];
    let close = lines.length - 1;
    for (let candidate = index + 1; candidate < lines.length; candidate += 1) {
      const match = lines[candidate].content.match(/^ {0,3}(`{3,}|~{3,})[ \t]*$/)?.[1];
      if (match && match[0] === marker && match.length >= opening.length) { close = candidate; break; }
    }
    const from = lines[index].from;
    const to = lines[close].to;
    output += source.slice(copiedUntil, from);
    const placeholder = uniquePlaceholder(source, protectedText.size, protectedText);
    protectedText.set(placeholder, source.slice(from, to));
    output += placeholder;
    copiedUntil = to;
    index = close;
  }
  return copiedUntil ? output + source.slice(copiedUntil) : source;
}

function protectInlineCode(source: string, protectedText: Map<string, string>): string {
  const pattern = /(`+)([^\r\n]*?)\1/g;
  let output = "";
  let copiedUntil = 0;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(source))) {
    output += source.slice(copiedUntil, match.index);
    const placeholder = uniquePlaceholder(source, protectedText.size, protectedText);
    protectedText.set(placeholder, match[0]);
    output += placeholder;
    copiedUntil = match.index + match[0].length;
  }
  return copiedUntil ? output + source.slice(copiedUntil) : source;
}

function protectDisplayMath(source: string, protectedText: Map<string, string>): string {
  const text = protectMatches(source, /\$\$[\s\S]*?\$\$/g, protectedText);
  const unclosed = text.indexOf("$$");
  if (unclosed < 0) return text;
  const placeholder = uniquePlaceholder(text, protectedText.size, protectedText);
  protectedText.set(placeholder, text.slice(unclosed));
  return text.slice(0, unclosed) + placeholder;
}

function protectSyntax(source: string): { text: string; protectedText: Map<string, string> } {
  const protectedText = new Map<string, string>();
  // Fences must be detected while their delimiters are still at line starts. A
  // front-matter placeholder intentionally has no newlines, so doing this in the
  // opposite order would hide a fence immediately following its closing line.
  let text = protectFencedCodeBlocks(source, protectedText);
  text = protectFrontMatter(text, protectedText);
  // Display maths and SSG fragments may contain Markdown-looking characters.
  text = protectDisplayMath(text, protectedText);
  text = protectMatches(text, /\{\{<[\s\S]*?>\}\}|\{\{[\s\S]*?\}\}|\{%[\s\S]*?%\}/g, protectedText);
  text = protectInlineCode(text, protectedText);
  text = protectMatches(text, /<[^>\r\n]+>/g, protectedText);
  // Keep the destination intact while still allowing the human-visible link label to be formatted.
  text = protectMatches(text, /(?<=\])\((?:\\.|[^()\r\n]|\([^()\r\n]*\))*\)/g, protectedText);
  return { text, protectedText };
}

function restoreSyntax(source: string, protectedText: Map<string, string>): string {
  let text = source;
  // A replacement string interprets `$` sequences (notably `$$` in display math),
  // so use a literal join. Restore nested placeholders last-in-first-out: front
  // matter can contain a previously protected fence, for example.
  for (const [placeholder, original] of [...protectedText.entries()].reverse()) text = text.split(placeholder).join(original);
  return text;
}

function newlinePair(newlines: string): string {
  const newline = newlines.includes("\r\n") ? "\r\n" : newlines.includes("\n") ? "\n" : "\r";
  return newline + newline;
}

/** Formats prose only; Markdown syntax and literal regions are left byte-for-byte unchanged. */
export function formatChineseTypography(source: string): string {
  if (!source) return source;
  const protectedSource = protectSyntax(source);
  let text = protectedSource.text;
  text = text.replace(new RegExp(`([${cjk}])([A-Za-z0-9])`, "gu"), "$1 $2");
  text = text.replace(new RegExp(`([A-Za-z0-9])([${cjk}])`, "gu"), "$1 $2");
  text = text.replace(new RegExp(`[ \\t]+([${punctuation}])`, "gu"), "$1");
  text = text.replace(new RegExp(`([${punctuation}])[ \\t]+`, "gu"), "$1");
  text = text.replace(/[ \t]+(?=\r?$)/gm, "");
  text = text.replace(/(?:\r\n|\n|\r){3,}/g, newlinePair);
  return restoreSyntax(text, protectedSource.protectedText);
}

/**
 * Formats a non-empty selection, or the complete document when the selection is empty.
 * JavaScript string indexes are UTF-16 code-unit indexes, the same convention used by
 * CodeMirror and `String#slice`.
 */
export function planChineseTypography(source: string, selection: TextRange): ChineseTypographyPlan {
  const selected = normalizedRange(source, selection);
  const hasSelection = selected.from !== selected.to;
  const target = hasSelection ? selected : { from: 0, to: source.length };
  if (target.from === target.to) return null;

  const original = source.slice(target.from, target.to);
  const formatted = formatChineseTypography(original);
  if (formatted === original) return null;
  return {
    text: source.slice(0, target.from) + formatted + source.slice(target.to),
    selection: hasSelection
      ? { from: target.from, to: target.from + formatted.length }
      : { from: 0, to: 0 },
  };
}
