import type {
  ArticleStateChangeInput,
  ArticleStateChangeResult,
  EditableArticleState,
} from "../../contracts/articleStateChange";
import type { ArticleStateIssueCode } from "../../contracts/articleState";
import { inspectFrontMatter } from "../frontmatter/frontMatter";
import { projectArticleState } from "./articleState";

const USER_WARNING_CODES = new Set<ArticleStateIssueCode>([
  "titleMissing",
  "dateMissing",
  "dateInvalid",
  "dateTimezoneUnknown",
  "dateFuture",
  "clockInvalid",
  "publicationUnverified",
]);

function splitLineEnding(line: string): { content: string; newline: string } {
  if (line.endsWith("\r\n")) return { content: line.slice(0, -2), newline: "\r\n" };
  if (line.endsWith("\n") || line.endsWith("\r")) return { content: line.slice(0, -1), newline: line.slice(-1) };
  return { content: line, newline: "" };
}

function locateDraftToken(
  field: string,
  style: "yaml" | "toml",
): { from: number; to: number; value: boolean } | null {
  const { content } = splitLineEnding(field);
  const match = style === "yaml"
    ? /^(draft[ \t]*:[ \t]*)(true|false)([ \t]*)$/.exec(content)
    : /^(draft[ \t]*=[ \t]*)(true|false)([ \t]*)$/.exec(content);
  if (!match) return null;
  const from = match[1].length;
  return { from, to: from + match[2].length, value: match[2] === "true" };
}

function headerNewline(source: string): string | null {
  const delimiterLength = 3;
  if (source.startsWith("\r\n", delimiterLength)) return "\r\n";
  if (source.startsWith("\n", delimiterLength)) return "\n";
  return null;
}

function closingDelimiterOffset(source: string, style: "yaml" | "toml"): number | null {
  const delimiter = style === "yaml" ? "---" : "+++";
  let lineStart = 0;
  let lineNumber = 0;
  while (lineStart <= source.length) {
    const newlineIndex = source.indexOf("\n", lineStart);
    const rawLine = newlineIndex < 0 ? source.slice(lineStart) : source.slice(lineStart, newlineIndex);
    const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
    if (lineNumber > 0 && (line === delimiter || (style === "yaml" && line === "..."))) return lineStart;
    if (newlineIndex < 0) return null;
    lineStart = newlineIndex + 1;
    lineNumber += 1;
  }
  return null;
}

function warningsFor(projection: ReturnType<typeof projectArticleState>): ArticleStateIssueCode[] {
  return projection.issues
    .map((item) => item.code)
    .filter((code) => USER_WARNING_CODES.has(code));
}

/**
 * Plans one local UTF-16 edit to the explicit draft flag. This function is
 * deliberately side-effect free; its caller must revalidate the bound text and
 * context before applying the returned edit.
 */
export function planArticleStateChange(
  input: ArticleStateChangeInput,
  target: EditableArticleState,
): ArticleStateChangeResult {
  if (target !== "draft" && target !== "ready") return { ok: false, reason: "invalidTarget" };

  const projection = projectArticleState(input);
  if (projection.scope !== "site") return { ok: false, reason: "notSiteArticle" };
  if (projection.readOnly) return { ok: false, reason: "readOnly" };
  if (projection.limited) return { ok: false, reason: "sizeLimit" };

  const issueCodes = new Set(projection.issues.map((item) => item.code));
  if (issueCodes.has("frontMatterMissing")) return { ok: false, reason: "frontMatterMissing" };
  if (issueCodes.has("frontMatterInvalid")) return { ok: false, reason: "frontMatterInvalid" };

  const bomOffset = input.text.charCodeAt(0) === 0xfeff ? 1 : 0;
  const source = bomOffset ? input.text.slice(bomOffset) : input.text;
  const snapshot = inspectFrontMatter(source);
  if (!snapshot) return { ok: false, reason: "frontMatterMissing" };
  if (snapshot.issue) return { ok: false, reason: "frontMatterInvalid" };

  const desiredValue = target === "draft";
  const draftRange = snapshot.fields.draft;
  let beforeField: string | null;
  let afterField: string;
  let edit: { from: number; to: number; insert: string };
  let selection: { from: number; to: number };

  if (draftRange) {
    beforeField = source.slice(draftRange.from, draftRange.to);
    const token = locateDraftToken(beforeField, snapshot.style);
    if (!token) return { ok: false, reason: "frontMatterInvalid" };
    if (token.value === desiredValue) return { ok: false, reason: "unchanged" };

    const insert = String(desiredValue);
    edit = {
      from: bomOffset + draftRange.from + token.from,
      to: bomOffset + draftRange.from + token.to,
      insert,
    };
    afterField = beforeField.slice(0, token.from) + insert + beforeField.slice(token.to);
    selection = { from: edit.from, to: edit.from + insert.length };
  } else {
    const newline = headerNewline(source);
    const closingOffset = closingDelimiterOffset(source, snapshot.style);
    if (!newline || closingOffset === null) return { ok: false, reason: "frontMatterInvalid" };

    const field = snapshot.style === "yaml" ? `draft: ${desiredValue}` : `draft = ${desiredValue}`;
    const insert = `${field}${newline}`;
    beforeField = null;
    afterField = insert;
    edit = { from: bomOffset + closingOffset, to: bomOffset + closingOffset, insert };
    selection = { from: edit.from, to: edit.from + field.length };
  }

  const nextText = input.text.slice(0, edit.from) + edit.insert + input.text.slice(edit.to);
  const nextProjection = projectArticleState({
    text: nextText,
    context: input.context,
    nowEpochMs: input.nowEpochMs,
  });
  if (nextProjection.limited) return { ok: false, reason: "sizeLimit" };
  if (nextProjection.scope !== "site" || nextProjection.state !== target) {
    return { ok: false, reason: "frontMatterInvalid" };
  }

  return {
    ok: true,
    plan: {
      target,
      contextKey: input.contextKey,
      expectedText: input.text,
      nextText,
      beforeField,
      afterField,
      edit,
      selection,
      warnings: warningsFor(projection),
    },
  };
}
