import type { TextEditResult, TextRange } from "./markdownWriting";
import { markdownFrontMatterBodyOffset } from "./markdownSyntaxContext";

/**
 * Plan the edit an editor should apply when the user types one Markdown
 * delimiter.  All offsets are JavaScript string offsets (UTF-16 code units),
 * matching TextRange and DOM/editor selection APIs.
 */
export function planMarkdownAutomaticPairing(
  source: string,
  input: TextRange,
  typedText: string,
): TextEditResult | null {
  if (typeof source !== "string" || !input || typeof typedText !== "string") return null;
  if (!Number.isFinite(input.from) || !Number.isFinite(input.to) || input.from < 0 || input.to < 0) return null;
  if (!Number.isInteger(input.from) || !Number.isInteger(input.to)) return null;
  if (typedText.length === 0 || typedText.length > 3 || /\r|\n/.test(typedText)) return null;

  // TextRange is UTF-16 based. Clamp an overlong editor range as the native
  // service does, and normalize reversed ranges for callers that provide them.
  const a = Math.min(source.length, input.from);
  const b = Math.min(source.length, input.to);
  const from = Math.min(a, b);
  const to = Math.max(a, b);
  if (from < markdownFrontMatterBodyOffset(source)) return null;
  if (typedText === "```" || typedText === "~~~") {
    const selected = source.slice(from, to);
    if (from === to) {
      const newline = preferredNewline(source);
      const replacement = typedText + newline + newline + typedText;
      return { text: source.slice(0, from) + replacement + source.slice(to), selection: { from: from + typedText.length + newline.length, to: from + typedText.length + newline.length } };
    }
    const newline = preferredNewline(source);
    const prefix = typedText + newline;
    const suffix = /(?:\r|\n)$/.test(selected) ? typedText : newline + typedText;
    return { text: source.slice(0, from) + prefix + selected + suffix + source.slice(to), selection: { from: from + prefix.length, to: from + prefix.length + selected.length } };
  }

  const pairs: Record<string, string> = {
    "(": ")", "[": "]", "{": "}",
    "（": "）", "【": "】", "《": "》",
    "\"": "\"", "'": "'", "“": "”", "‘": "’", "`": "`",
  };

  // A straight quote immediately after a word is overwhelmingly apostrophe /
  // inch punctuation. Match the AppKit editor's context rule.
  if (from === to && (typedText === "\"" || typedText === "'") && from > 0) {
    const previous = codePointBefore(source, from);
    if (/^[\p{L}\p{N}]$/u.test(previous)) return null;
  }

  // Typing a closing delimiter already under the caret should advance over it
  // without inserting a duplicate. This includes symmetric quote/backtick.
  if (from === to && source.slice(from, from + typedText.length) === typedText && isClosingSymbol(typedText)) {
    return { text: source, selection: { from: from + typedText.length, to: from + typedText.length } };
  }

  const closing = pairs[typedText];
  if (!closing) return null;

  const selected = source.slice(from, to);
  const replacement = typedText + selected + closing;
  return { text: source.slice(0, from) + replacement + source.slice(to), selection: { from: from + typedText.length, to: from + typedText.length + selected.length } };
}

function isClosingSymbol(value: string): boolean {
  return [")", "]", "}", "）", "】", "》", "”", "’", "\"", "'", "`"].includes(value);
}

function codePointBefore(value: string, index: number): string {
  if (index <= 0) return "";
  const unit = value.charCodeAt(index - 1);
  const start = unit >= 0xdc00 && unit <= 0xdfff && index >= 2 ? index - 2 : index - 1;
  return String.fromCodePoint(value.codePointAt(start) ?? 0);
}

function preferredNewline(source: string): "\n" | "\r\n" {
  return source.includes("\r\n") ? "\r\n" : "\n";
}
