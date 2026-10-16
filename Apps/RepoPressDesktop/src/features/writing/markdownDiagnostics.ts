import type { DiagnosticPresentation, UiMessage } from "../../i18n/uiMessage";
import { getMarkdownImageReferences } from "./markdownImageMetadata";
import { isMarkdownEscaped, markdownFrontMatterBodyOffset, transitionMarkdownFence, type MarkdownFenceState } from "./markdownSyntaxContext";

/** Severity suitable for an editor gutter, list, or inline decoration. */
export type MarkdownDiagnosticSeverity = "warning" | "error";

/** A half-open UTF-16 range. It deliberately matches JavaScript string offsets. */
export interface MarkdownDiagnosticRange { from: number; to: number }

export interface MarkdownDiagnostic {
  id: string;
  severity: MarkdownDiagnosticSeverity;
  title: string;
  message: string;
  /** Optional local display templates. Ranges and replacements remain language independent. */
  presentation?: DiagnosticPresentation;
  range: MarkdownDiagnosticRange;
  /** Earlier source location that helps explain this diagnostic. */
  related?: { range: MarkdownDiagnosticRange; line: number };
  /** Safe replacement for range, when one can be made without guessing intent. */
  replacement?: string;
  /** Snapshot of range when the diagnostic was generated, used to reject stale fixes. */
  expectedText?: string;
}

export interface MarkdownDiagnosticContext {
  /** Article names and/or Markdown paths available to an internal wiki link. */
  knownArticleTitles?: Iterable<string>;
  /** Caller-owned normalized wiki targets for repository-wide reuse. */
  normalizedKnownArticleTitles?: ReadonlySet<string>;
  /** Optional caller-owned response bound. The editor leaves this unset. */
  maxIssues?: number;
}

export interface MarkdownDiagnosticFixResult {
  text: string;
  selection: MarkdownDiagnosticRange;
}

interface Line { from: number; to: number; text: string; visible: string }

interface MarkdownHeading {
  level: number;
  hashFrom: number;
  title: string;
  line: number;
  range: MarkdownDiagnosticRange;
}

type HtmlBlockState =
  | { kind: "comment" | "processing" | "declaration" | "cdata" }
  | { kind: "raw"; tag: string }
  | { kind: "until-blank" };

const htmlBlockTags = "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul";
const htmlBlockTagPattern = new RegExp(`^ {0,3}</?(?:${htmlBlockTags})(?=[\\t />]|$)`, "i");
const completeHtmlTagPattern = /^ {0,3}<\/?[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[^<>]*)?\/?>(?:[ \t]*)$/;

function closesHtmlBlock(line: string, state: HtmlBlockState): boolean {
  if (state.kind === "comment") return line.includes("-->");
  if (state.kind === "processing") return line.includes("?>");
  if (state.kind === "declaration") return line.includes(">");
  if (state.kind === "cdata") return line.includes("]]>");
  if (state.kind === "raw") return new RegExp(`</${state.tag}[ \\t]*>`, "i").test(line);
  return false;
}

function openedHtmlBlock(line: string): HtmlBlockState | null {
  if (/^ {0,3}<!--/.test(line)) return line.includes("-->") ? null : { kind: "comment" };
  if (/^ {0,3}<\?/.test(line)) return line.includes("?>") ? null : { kind: "processing" };
  if (/^ {0,3}<!\[CDATA\[/.test(line)) return line.includes("]]>") ? null : { kind: "cdata" };
  if (/^ {0,3}<![A-Z]/.test(line)) return line.includes(">") ? null : { kind: "declaration" };
  const raw = line.match(/^ {0,3}<(script|pre|style|textarea)(?=[\t >]|$)/i);
  if (raw) return new RegExp(`</${raw[1]}[ \\t]*>`, "i").test(line) ? null : { kind: "raw", tag: raw[1] };
  if (htmlBlockTagPattern.test(line) || completeHtmlTagPattern.test(line)) return { kind: "until-blank" };
  return null;
}

/**
 * Parses bounded ATX headings without interpreting their inline contents. Structural
 * exclusions are tracked before examining a line; title identity comes from source text
 * so inline code, escapes, literal underscores, and literal asterisks remain meaningful.
 */
function markdownHeadings(source: string): MarkdownHeading[] {
  const headings: MarkdownHeading[] = [];
  const bodyOffset = markdownFrontMatterBodyOffset(source);
  let fence: MarkdownFenceState = { marker: null, length: 0 };
  let htmlBlock: HtmlBlockState | null = null;
  let lineNumber = 0;
  for (const line of linesFor(source, source)) {
    lineNumber += 1;
    if (line.from < bodyOffset) continue;

    // Raw HTML is not parsed as Markdown. Its terminators therefore remain meaningful
    // even when they contain backticks that would be inline-code delimiters in prose.
    if (htmlBlock?.kind === "until-blank" && /^[ \t]*$/.test(line.text)) {
      htmlBlock = null;
      continue;
    }
    if (htmlBlock) {
      if (closesHtmlBlock(line.text, htmlBlock)) htmlBlock = null;
      continue;
    }

    // HTML can only start outside a fence, while fence-looking lines inside HTML stay raw HTML.
    const wasFenced = Boolean(fence.marker);
    const transition = transitionMarkdownFence(line.text, fence);
    fence = transition.state;
    if (wasFenced || transition.delimiterLine) continue;

    // HTML block openers must begin the structural line; inline-code contents cannot open one.
    const opened = openedHtmlBlock(line.text);
    if (opened || /^ {0,3}(?:<!--|<\?|<!\[CDATA\[|<![A-Z])/.test(line.text)) {
      htmlBlock = opened;
      continue;
    }

    // Four leading spaces are an indented code block; 1-6 hashes require whitespace or EOL.
    const original = line.text.match(/^ {0,3}(#{1,6})(?:[ \t]+(.*)|[ \t]*)$/);
    if (!original) continue;
    let title = original[2] ?? "";
    title = title.replace(/[ \t]+$/, "");
    // A closing sequence is only closing syntax when whitespace precedes it. Thus C# stays C#.
    title = title.replace(/(?:^|[ \t]+)#+$/, "").trim();
    const hashFrom = line.from + original[0].indexOf(original[1]);
    headings.push({
      level: original[1].length,
      hashFrom,
      title,
      line: lineNumber,
      range: { from: line.from, to: line.to },
    });
  }
  return headings;
}

function normalizedHeadingTitle(value: string): string | null {
  const normalized = value.normalize("NFKC").replace(/\s+/gu, " ").trim().toLowerCase();
  return normalized || null;
}

function compareDiagnostics(left: MarkdownDiagnostic, right: MarkdownDiagnostic): number {
  return left.range.from - right.range.from || left.range.to - right.range.to || left.id.localeCompare(right.id);
}

function siftDiagnosticUp(heap: MarkdownDiagnostic[], from: number): void {
  let index = from;
  while (index > 0) {
    const parent = Math.floor((index - 1) / 2);
    if (compareDiagnostics(heap[parent], heap[index]) >= 0) break;
    [heap[parent], heap[index]] = [heap[index], heap[parent]];
    index = parent;
  }
}

function siftDiagnosticDown(heap: MarkdownDiagnostic[], from: number): void {
  let index = from;
  while (true) {
    const left = index * 2 + 1;
    if (left >= heap.length) return;
    const right = left + 1;
    const laterChild = right < heap.length && compareDiagnostics(heap[right], heap[left]) > 0 ? right : left;
    if (compareDiagnostics(heap[index], heap[laterChild]) >= 0) return;
    [heap[index], heap[laterChild]] = [heap[laterChild], heap[index]];
    index = laterChild;
  }
}

function mask(characters: string[], from: number, to: number): void {
  for (let index = from; index < to; index += 1) if (characters[index] !== "\n" && characters[index] !== "\r") characters[index] = " ";
}

function maskInlineCode(characters: string[], source: string, from: number, to: number): void {
  let cursor = from;
  while (cursor < to) {
    if (source[cursor] !== "`" || isMarkdownEscaped(source, cursor)) { cursor += 1; continue; }
    let openingEnd = cursor + 1;
    while (openingEnd < to && source[openingEnd] === "`") openingEnd += 1;
    const delimiter = source.slice(cursor, openingEnd);
    let closing = source.indexOf(delimiter, openingEnd);
    while (closing >= 0 && closing < to && (source[closing - 1] === "`" || source[closing + delimiter.length] === "`")) closing = source.indexOf(delimiter, closing + delimiter.length);
    if (closing < 0 || closing >= to) { cursor = openingEnd; continue; }
    mask(characters, cursor, closing + delimiter.length);
    cursor = closing + delimiter.length;
  }
}

/**
 * Produces a same-length view that hides front matter, fenced code, and paired inline code.
 * Keeping code units in place is what makes every range usable by textarea and CodeMirror.
 */
function visibleMarkdown(source: string): string {
  const characters = source.split("");
  const bodyOffset = markdownFrontMatterBodyOffset(source);
  let fence: MarkdownFenceState = { marker: null, length: 0 };
  let from = 0;
  while (from < source.length) {
    const newline = source.indexOf("\n", from);
    const to = newline < 0 ? source.length : newline;
    const next = newline < 0 ? source.length : newline + 1;
    const line = source.slice(from, to).replace(/\r$/, "");
    if (from < bodyOffset) {
      mask(characters, from, next);
    } else {
      const wasFenced = Boolean(fence.marker);
      const transition = transitionMarkdownFence(line, fence);
      fence = transition.state;
      if (wasFenced || transition.delimiterLine) mask(characters, from, next);
      else maskInlineCode(characters, source, from, to);
    }
    from = next;
  }
  return characters.join("");
}

function linesFor(source: string, visible: string): Line[] {
  const lines: Line[] = [];
  let from = 0;
  while (from <= source.length) {
    const newline = source.indexOf("\n", from);
    const to = newline < 0 ? source.length : newline;
    lines.push({ from, to, text: source.slice(from, to).replace(/\r$/, ""), visible: visible.slice(from, to).replace(/\r$/, "") });
    if (newline < 0) break;
    from = newline + 1;
  }
  return lines;
}

function diagnostic(id: string, severity: MarkdownDiagnosticSeverity, title: string, message: string, from: number, to: number, replacement?: string, messagePresentation?: UiMessage): MarkdownDiagnostic {
  const result: MarkdownDiagnostic = { id, severity, title, message, range: { from, to },
    presentation: { title: { source: title }, message: messagePresentation ?? { source: message } } };
  if (replacement !== undefined) {
    result.replacement = replacement;
    // Filled by the caller from the original source to keep this helper range-only.
  }
  return result;
}

function imageAltSuggestion(path: string): string {
  const pathWithoutQuery = path.split(/[?#]/, 1)[0] ?? "";
  const name = pathWithoutQuery.split(/[\\/]/).pop()?.replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ").replace(/\s+/g, " ").trim();
  return name || "图片说明";
}

function normalizedWikiTarget(value: string): string | null {
  let target = value.split("|", 1)[0]?.split("#", 1)[0]?.trim() ?? "";
  if (!target) return null;
  try { target = decodeURIComponent(target); } catch { /* A literal percent sign is still a valid title. */ }
  target = target.replace(/\\/g, "/").replace(/^\.\//, "").replace(/\.(?:md|markdown|mdx)$/i, "");
  target = target.normalize("NFKC").replace(/\s+/g, " ").toLowerCase();
  return target || null;
}

function wikiTargetVariants(value: string): string[] {
  const normalized = normalizedWikiTarget(value);
  if (!normalized) return [];
  const leaf = normalized.split("/").filter(Boolean).pop();
  return leaf && leaf !== normalized ? [normalized, leaf] : [normalized];
}

function isMarkdownDestination(visible: string, from: number): boolean {
  const prefix = visible.slice(Math.max(0, from - 80), from);
  if (/\]\(\s*<?$/.test(prefix) || /<\s*$/.test(prefix)) return true;
  const lineStart = visible.lastIndexOf("\n", from - 1) + 1;
  return /^\s{0,3}\[[^\]]+\]:\s*<?[^\s]*$/.test(visible.slice(lineStart, from));
}

function unclosedFenceDiagnostic(source: string): MarkdownDiagnostic | null {
  const bodyOffset = markdownFrontMatterBodyOffset(source);
  let current: { marker: "`" | "~"; length: number; from: number } | null = null;
  for (const line of linesFor(source, source)) {
    if (line.from < bodyOffset) continue;
    const match = line.text.match(/^ {0,3}(`{3,}|~{3,})/);
    if (!match) continue;
    const marker = match[1][0] as "`" | "~";
    const length = match[1].length;
    const markerFrom = line.from + match.index! + match[0].length - length;
    if (!current) { current = { marker, length, from: markerFrom }; continue; }
    const afterMarker = line.text.slice((match.index ?? 0) + match[0].length);
    if (marker === current.marker && length >= current.length && /^[ \t]*$/.test(afterMarker)) current = null;
  }
  if (!current) return null;
  return diagnostic(`unclosed-code-fence-${current.from}`, "error", "代码围栏没有闭合", "该代码块缺少结束围栏，后续内容可能不会按 Markdown 渲染。", current.from, current.from + current.length);
}

/** Returns source-ordered diagnostics. Ranges always use JavaScript UTF-16 offsets. */
export function getMarkdownDiagnostics(source: string, context: MarkdownDiagnosticContext = {}): MarkdownDiagnostic[] {
  const maximumIssues = context.maxIssues === undefined
    ? Number.POSITIVE_INFINITY
    : Math.max(0, Math.min(100_000, Math.floor(Number.isFinite(context.maxIssues) ? context.maxIssues : 0)));
  if (maximumIssues === 0) return [];

  const visible = visibleMarkdown(source);
  // With a finite response cap this array is a max-heap. Its root is the latest retained
  // source location, so later diagnostics can be discarded in O(1) or replaced in O(log cap).
  const diagnostics: MarkdownDiagnostic[] = [];
  const bounded = Number.isFinite(maximumIssues);
  const prepare = (item: MarkdownDiagnostic) => {
    if (item.replacement !== undefined) item.expectedText = source.slice(item.range.from, item.range.to);
  };
  const add = (item: MarkdownDiagnostic) => {
    if (!bounded) {
      prepare(item);
      diagnostics.push(item);
      return;
    }
    if (diagnostics.length < maximumIssues) {
      prepare(item);
      diagnostics.push(item);
      siftDiagnosticUp(diagnostics, diagnostics.length - 1);
      return;
    }
    if (compareDiagnostics(item, diagnostics[0]) >= 0) return;
    prepare(item);
    diagnostics[0] = item;
    siftDiagnosticDown(diagnostics, 0);
  };

  for (const reference of getMarkdownImageReferences(source)) {
    if (reference.alt.trim()) continue;
    const open = reference.from + 1;
    const close = source.indexOf("]", open + 1);
    if (close < 0 || close >= reference.to) continue;
    add(diagnostic(`image-alt-${reference.from}`, "warning", "图片缺少 alt 文本", "补充替代文本可改善无障碍与搜索表现。", open, close + 1, `[${imageAltSuggestion(reference.path)}]`));
  }

  let previousHeadingLevel: number | null = null;
  const seenHeadings = new Map<string, { range: MarkdownDiagnosticRange; line: number }>();
  for (const heading of markdownHeadings(source)) {
    const { level, hashFrom } = heading;
    if (previousHeadingLevel !== null && level > previousHeadingLevel + 1) {
      const replacement = "#".repeat(previousHeadingLevel + 1);
      add(diagnostic(`heading-jump-${hashFrom}`, "warning", "标题层级跳跃", `H${previousHeadingLevel} 后直接使用 H${level}，建议调整为 H${previousHeadingLevel + 1}。`, hashFrom, hashFrom + level, replacement, { source: "H{previous} 后直接使用 H{level}，建议调整为 H{suggested}。", parameters: { previous: previousHeadingLevel, level, suggested: previousHeadingLevel + 1 } }));
    }
    const normalizedTitle = normalizedHeadingTitle(heading.title);
    const first = normalizedTitle ? seenHeadings.get(normalizedTitle) : undefined;
    if (first) {
      const item = diagnostic(
        `duplicate-heading-${heading.range.from}`,
        "warning",
        "标题重复",
        `与第 ${first.line} 行的标题重复，建议使用更具体的章节名。`,
        heading.range.from,
        heading.range.to,
        undefined,
        { source: "与第 {line} 行的标题重复，建议使用更具体的章节名。", parameters: { line: first.line } },
      );
      item.related = { range: { ...first.range }, line: first.line };
      add(item);
    } else if (normalizedTitle) {
      seenHeadings.set(normalizedTitle, { range: { ...heading.range }, line: heading.line });
    }
    previousHeadingLevel = level;
  }

  const definitions = new Set<string>();
  for (const line of linesFor(source, visible)) {
    const match = line.visible.match(/^ {0,3}\[\^([^\]\n]+)\]:/);
    if (match) definitions.add(match[1]);
  }
  for (const match of visible.matchAll(/\[\^([^\]\n]+)\]/g)) {
    const name = match[1];
    if (definitions.has(name)) continue;
    const from = match.index!;
    add(diagnostic(`missing-footnote-${from}`, "error", "脚注没有定义", `为 [^${name}] 添加对应的脚注内容。`, from, from + match[0].length, undefined, { source: "为 [^{name}] 添加对应的脚注内容。", parameters: { name } }));
  }

  for (const match of visible.matchAll(/https?:\/\/[^\s<>()]+/gi)) {
    const from = match.index!;
    let url = match[0];
    // Sentence punctuation is not normally part of a pasted URL.
    url = url.replace(/[.,;:!?。！？；：]+$/, "");
    if (!url || isMarkdownDestination(visible, from)) continue;
    add(diagnostic(`bare-url-${from}`, "warning", "链接缺少说明文字", "把裸露网址改成有意义的链接文字，可改善可读性和无障碍体验。", from, from + url.length, `[链接](${url})`));
  }

  for (const line of linesFor(source, visible)) {
    const match = line.visible.match(/^([ \t]*\d+、)([^\s])/);
    if (!match) continue;
    const from = line.from + match[1].length - match[1].trimStart().length;
    const marker = match[1].trimStart();
    add(diagnostic(`ordered-list-space-${from}`, "warning", "有序列表后缺少空格", "中文有序列表标记后建议保留一个空格，以确保一致地解析为列表。", from, from + marker.length, `${marker} `));
  }

  const unclosedFence = unclosedFenceDiagnostic(source);
  if (unclosedFence) add(unclosedFence);

  let known: ReadonlySet<string> = context.normalizedKnownArticleTitles ?? new Set<string>();
  if (!context.normalizedKnownArticleTitles && context.knownArticleTitles) {
    const normalized = new Set<string>();
    for (const title of context.knownArticleTitles) for (const variant of wikiTargetVariants(title)) normalized.add(variant);
    known = normalized;
  }
  if (known.size) {
    for (const match of visible.matchAll(/\[\[([^\]\n]+)\]\]/g)) {
      const rawTarget = match[1];
      const variants = wikiTargetVariants(rawTarget);
      if (!variants.length || variants.some((variant) => known.has(variant))) continue;
      const from = match.index!;
      add(diagnostic(`missing-internal-link-${from}`, "error", "内部链接目标不存在", `没有找到题为“${rawTarget.split("|", 1)[0]?.split("#", 1)[0]?.trim() || rawTarget}”的文章。`, from, from + match[0].length, undefined, { source: "没有找到题为“{target}”的文章。", parameters: { target: rawTarget.split("|", 1)[0]?.split("#", 1)[0]?.trim() || rawTarget } }));
    }
  }

  return diagnostics.sort(compareDiagnostics);
}

/** Applies a quick fix only if the range still contains the text it was diagnosed against. */
export function applyMarkdownDiagnosticFix(source: string, item: MarkdownDiagnostic): MarkdownDiagnosticFixResult | null {
  if (item.replacement === undefined || item.expectedText === undefined) return null;
  const { from, to } = item.range;
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from || to > source.length) return null;
  if (source.slice(from, to) !== item.expectedText) return null;
  const text = source.slice(0, from) + item.replacement + source.slice(to);
  const cursor = from + item.replacement.length;
  return { text, selection: { from: cursor, to: cursor } };
}
