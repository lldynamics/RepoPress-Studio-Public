import type { FindOptions, Match, TextEditResult, TextRange } from "./markdownWriting";
import { inspectMatches, replaceAll } from "./markdownWriting";
import { parseFrontMatter } from "../frontmatter/frontMatter";

export type MarkdownFindReplaceScope = "body" | "selection";

export interface FrozenMarkdownSelection {
  documentKey: string;
  expectedValue: string;
  range: TextRange;
  selectedText: string;
}

export interface MarkdownFindReplacePreview {
  documentKey: string;
  expectedValue: string;
  scope: MarkdownFindReplaceScope;
  range: TextRange;
  query: string;
  replacement: string;
  options: Required<FindOptions>;
  originalText: string;
  proposedText: string;
  replacementCount: number;
}

export interface ScopedFindResult {
  range: TextRange | null;
  matches: Match[];
  error: string | null;
}

export interface PreviewPlanResult {
  preview: MarkdownFindReplacePreview | null;
  error: string | null;
}

export interface PreviewApplyResult {
  edit: TextEditResult | null;
  error: string | null;
}

// The preview deliberately has a small, explicit budget: it must display the
// entire proposed change, never crop it or silently replace only a subset.
export const MARKDOWN_FIND_REPLACE_MAX_SCOPE_LENGTH = 256 * 1024;
export const MARKDOWN_FIND_REPLACE_MAX_DOCUMENT_LENGTH = 512 * 1024;
export const MARKDOWN_FIND_REPLACE_MAX_MATCHES = 2_000;
const MAX_QUERY_LENGTH = 512;
const MAX_REPLACEMENT_LENGTH = 4 * 1024;

function normalizedOptions(options: FindOptions): Required<FindOptions> {
  return { caseSensitive: Boolean(options.caseSensitive), wholeWord: Boolean(options.wholeWord), regularExpression: Boolean(options.regularExpression) };
}

export function createMarkdownFindReplacePreview(input: {
  value: string;
  documentKey?: string;
  scope: MarkdownFindReplaceScope;
  range: TextRange;
  query: string;
  replacement: string;
  options?: FindOptions;
  proposedText: string;
  replacementCount: number;
}): MarkdownFindReplacePreview {
  return {
    documentKey: input.documentKey ?? "",
    expectedValue: input.value,
    scope: input.scope,
    range: input.range,
    query: input.query,
    replacement: input.replacement,
    options: normalizedOptions(input.options ?? {}),
    originalText: input.value.slice(input.range.from, input.range.to),
    proposedText: input.proposedText,
    replacementCount: input.replacementCount,
  };
}

function validRange(value: string, input: TextRange): TextRange | null {
  if (!Number.isInteger(input.from) || !Number.isInteger(input.to)) return null;
  const from = Math.min(input.from, input.to);
  const to = Math.max(input.from, input.to);
  if (from < 0 || to > value.length || from === to) return null;
  return { from, to };
}

/** Returns the Markdown body after a parsed YAML or TOML front matter block. */
export function markdownBodyRange(value: string): TextRange {
  if (value.length > MARKDOWN_FIND_REPLACE_MAX_DOCUMENT_LENGTH) return { from: 0, to: value.length };
  return markdownBodyScope(value).range;
}

function markdownBodyScope(value: string): { range: TextRange; error: string | null } {
  if (value.length > MARKDOWN_FIND_REPLACE_MAX_DOCUMENT_LENGTH) {
    return { range: { from: 0, to: value.length }, error: `文稿超过 ${MARKDOWN_FIND_REPLACE_MAX_DOCUMENT_LENGTH.toLocaleString()} 个 UTF-16 字符，无法安全查找替换。` };
  }
  const frontMatter = parseFrontMatter(value);
  if (frontMatter?.issue) {
    return { range: { from: frontMatter.bodyOffset, to: value.length }, error: `无法确认正文范围：Front Matter ${frontMatter.issue}` };
  }
  return { range: { from: frontMatter?.bodyOffset ?? 0, to: value.length }, error: null };
}

export function markdownBodyScopeError(value: string): string | null {
  return markdownBodyScope(value).error;
}

export function freezeMarkdownSelection(value: string, selection: TextRange, documentKey?: string): FrozenMarkdownSelection | null {
  const range = validRange(value, selection);
  const bodyScope = markdownBodyScope(value);
  if (bodyScope.error || !range || range.from < bodyScope.range.from || range.to > bodyScope.range.to) return null;
  return { documentKey: documentKey ?? "", expectedValue: value, range, selectedText: value.slice(range.from, range.to) };
}

export function frozenMarkdownSelectionIsCurrent(snapshot: FrozenMarkdownSelection | null, value: string, documentKey?: string): boolean {
  return Boolean(snapshot
    && snapshot.documentKey === (documentKey ?? "")
    && snapshot.expectedValue === value
    && value.slice(snapshot.range.from, snapshot.range.to) === snapshot.selectedText);
}

export function findScopeRange(value: string, scope: MarkdownFindReplaceScope, selection: FrozenMarkdownSelection | null, documentKey?: string): TextRange | null {
  return scope === "body"
    ? markdownBodyRange(value)
    : frozenMarkdownSelectionIsCurrent(selection, value, documentKey) ? selection!.range : null;
}

function scopeBudgetError(text: string): string | null {
  if (text.length > MARKDOWN_FIND_REPLACE_MAX_SCOPE_LENGTH) return `范围超过 ${MARKDOWN_FIND_REPLACE_MAX_SCOPE_LENGTH.toLocaleString()} 个 UTF-16 字符，无法安全预览。`;
  return null;
}

function inputError(query: string, replacement: string): string | null {
  if (!query) return "请输入要查找的内容。";
  if (query.length > MAX_QUERY_LENGTH) return `查找内容超过 ${MAX_QUERY_LENGTH} 个 UTF-16 字符。`;
  if (replacement.length > MAX_REPLACEMENT_LENGTH) return `替换内容超过 ${MAX_REPLACEMENT_LENGTH.toLocaleString()} 个 UTF-16 字符。`;
  return null;
}

/** Finds only literal text. Regular expressions are intentionally excluded from this bounded preview path. */
export function findInMarkdownScope(value: string, range: TextRange | null, query: string, options: FindOptions = {}): ScopedFindResult {
  const documentProblem = markdownBodyScopeError(value);
  if (!range) return { range: null, matches: [], error: "仅选区需要在正文中选择非空内容；选择已失效。" };
  const text = value.slice(range.from, range.to);
  const inputProblem = inputError(query, "");
  const budgetProblem = scopeBudgetError(text);
  if (documentProblem || inputProblem || budgetProblem) return { range, matches: [], error: documentProblem || inputProblem || budgetProblem };
  const inspected = inspectMatches(text, query, normalizedOptions(options));
  if (inspected.error) return { range, matches: [], error: inspected.error };
  if (inspected.matches.length > MARKDOWN_FIND_REPLACE_MAX_MATCHES) {
    return { range, matches: [], error: `匹配超过 ${MARKDOWN_FIND_REPLACE_MAX_MATCHES.toLocaleString()} 处，无法安全预览。` };
  }
  return { range, matches: inspected.matches.map((match) => ({ from: range.from + match.from, to: range.from + match.to })), error: null };
}

export function planMarkdownFindReplacePreview(input: {
  value: string;
  documentKey?: string;
  scope: MarkdownFindReplaceScope;
  selection: FrozenMarkdownSelection | null;
  query: string;
  replacement: string;
  options?: FindOptions;
}): PreviewPlanResult {
  if (input.value.length > MARKDOWN_FIND_REPLACE_MAX_DOCUMENT_LENGTH) return { preview: null, error: `文稿超过 ${MARKDOWN_FIND_REPLACE_MAX_DOCUMENT_LENGTH.toLocaleString()} 个 UTF-16 字符，无法安全查找替换。` };
  const documentProblem = markdownBodyScopeError(input.value);
  const bodyProblem = input.scope === "body" ? markdownBodyScope(input.value).error : null;
  const range = findScopeRange(input.value, input.scope, input.selection, input.documentKey);
  const scoped = findInMarkdownScope(input.value, range, input.query, input.options);
  const valueProblem = inputError(input.query, input.replacement);
  if (!range || documentProblem || bodyProblem || scoped.error || valueProblem) return { preview: null, error: documentProblem || bodyProblem || scoped.error || valueProblem || "无法确定替换范围。" };
  const options = normalizedOptions(input.options ?? {});
  const replacement = replaceAll(input.value.slice(range.from, range.to), input.query, input.replacement, options);
  if (replacement.replacementCount !== scoped.matches.length) return { preview: null, error: "查找结果已变化，请重新预览。" };
  if (replacement.text.length > MARKDOWN_FIND_REPLACE_MAX_SCOPE_LENGTH) {
    return { preview: null, error: `替换后的范围超过 ${MARKDOWN_FIND_REPLACE_MAX_SCOPE_LENGTH.toLocaleString()} 个字符，无法安全预览。` };
  }
  return { preview: createMarkdownFindReplacePreview({ ...input, range, proposedText: replacement.text, replacementCount: replacement.replacementCount }), error: null };
}

export function applyMarkdownFindReplacePreview(preview: MarkdownFindReplacePreview, value: string, documentKey?: string, readOnly = false): PreviewApplyResult {
  if (readOnly) return { edit: null, error: "文档为只读，预览已失效。" };
  if (preview.documentKey !== (documentKey ?? "") || preview.expectedValue !== value) return { edit: null, error: "文稿已经变化，预览已失效，请重新预览。" };
  if (value.slice(preview.range.from, preview.range.to) !== preview.originalText) return { edit: null, error: "替换范围已经变化，预览已失效，请重新预览。" };
  return {
    edit: {
      text: value.slice(0, preview.range.from) + preview.proposedText + value.slice(preview.range.to),
      selection: { from: preview.range.from, to: preview.range.from },
    },
    error: null,
  };
}
