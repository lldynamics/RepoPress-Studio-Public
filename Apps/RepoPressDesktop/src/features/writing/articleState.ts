import type {
  ArticleStateContext,
  ArticleStateInput,
  ArticleStateIssue,
  ArticleStateLocation,
  ArticleStateProjection,
} from "../../contracts/articleState";
import { inspectFrontMatter } from "../frontmatter/frontMatter";

export const MAX_ARTICLE_STATE_BYTES = 256 * 1024;

const SITE_KINDS = new Set(["hugo", "zola", "astro", "jekyll", "nextjs", "vitepress", "quartz", "hexo", "foam"]);
const FRONT_MATTER_FIELDS = new Set(["title", "date", "slug", "permalink", "description", "cover", "tags", "categories", "draft"]);
const FRONT_MATTER_ARRAY_FIELDS = new Set(["tags", "categories"]);
const FRONT_MATTER_STRING_FIELDS = new Set(["title", "date", "slug", "permalink", "description", "cover"]);
const MAX_DATE_EPOCH_MS = 8_640_000_000_000_000;

type DateProjection = ArticleStateProjection["date"];

function issue(
  code: ArticleStateIssue["code"],
  location: ArticleStateLocation | null,
  severity: ArticleStateIssue["severity"] = "warning",
): ArticleStateIssue {
  return { code, severity, location };
}

function utf8ByteLength(value: string): number {
  if (value.length > MAX_ARTICLE_STATE_BYTES) return value.length;
  return new TextEncoder().encode(value).byteLength;
}

function isSafeRelativePath(value: string): boolean {
  if (!value || value.startsWith("/") || value.startsWith("\\") || /^[A-Za-z]:/.test(value)) return false;
  if (value.includes("\\") || value.includes("\0")) return false;
  const segments = value.split("/");
  return segments.every((segment) => segment !== "" && segment !== "." && segment !== "..");
}

function repositoryScope(context: Extract<ArticleStateContext, { kind: "repository" }>): {
  scope: ArticleStateProjection["scope"];
  scopeIssue: ArticleStateIssue | null;
} {
  if (!SITE_KINDS.has(context.repository.siteKind.trim().toLowerCase())) {
    return { scope: "unknown", scopeIssue: issue("siteUnknown", { kind: "site" }) };
  }

  const contentRoot = context.repository.contentRoot;
  if (contentRoot === null || !isSafeRelativePath(contentRoot) || !isSafeRelativePath(context.relativePath)) {
    return { scope: "unknown", scopeIssue: issue("invalidPath", { kind: "site" }) };
  }

  const rootSegments = contentRoot.split("/");
  const pathSegments = context.relativePath.split("/");
  const isStrictDescendant = pathSegments.length > rootSegments.length
    && rootSegments.every((segment, index) => pathSegments[index] === segment);
  if (!isStrictDescendant) {
    return { scope: "outsideSite", scopeIssue: issue("outsideContentRoot", { kind: "site" }) };
  }
  return { scope: "site", scopeIssue: null };
}

function validClock(value: number): boolean {
  return Number.isFinite(value) && Math.abs(value) <= MAX_DATE_EPOCH_MS;
}

function componentsAreReal(year: number, month: number, day: number, hour = 0, minute = 0, second = 0): boolean {
  if (month < 1 || month > 12 || day < 1 || hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) return false;
  const probe = new Date(0);
  probe.setUTCFullYear(year, month - 1, day);
  probe.setUTCHours(hour, minute, second, 0);
  return probe.getUTCFullYear() === year
    && probe.getUTCMonth() === month - 1
    && probe.getUTCDate() === day
    && probe.getUTCHours() === hour
    && probe.getUTCMinutes() === minute
    && probe.getUTCSeconds() === second;
}

function parseDate(value: string): { kind: "invalid" | "timezoneUnknown" | "zoned"; epochMs: number | null } {
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (dateOnly) {
    const [, year, month, day] = dateOnly.map(Number);
    return componentsAreReal(year, month, day)
      ? { kind: "timezoneUnknown", epochMs: null }
      : { kind: "invalid", epochMs: null };
  }

  const dateTime = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:(Z)|([+-])(\d{2}):(\d{2}))?$/.exec(value);
  if (!dateTime) return { kind: "invalid", epochMs: null };

  const year = Number(dateTime[1]);
  const month = Number(dateTime[2]);
  const day = Number(dateTime[3]);
  const hour = Number(dateTime[4]);
  const minute = Number(dateTime[5]);
  const second = Number(dateTime[6]);
  if (!componentsAreReal(year, month, day, hour, minute, second)) return { kind: "invalid", epochMs: null };

  const fraction = dateTime[7] ?? "";
  const milliseconds = Number(`${fraction}000`.slice(0, 3));
  const isZulu = dateTime[8] === "Z";
  const offsetSign = dateTime[9];
  if (!isZulu && !offsetSign) return { kind: "timezoneUnknown", epochMs: null };

  const offsetHours = offsetSign ? Number(dateTime[10]) : 0;
  const offsetMinutes = offsetSign ? Number(dateTime[11]) : 0;
  if (offsetHours > 14 || offsetMinutes > 59 || (offsetHours === 14 && offsetMinutes !== 0)) {
    return { kind: "invalid", epochMs: null };
  }
  if (offsetSign === "-" && offsetHours === 0 && offsetMinutes === 0) {
    return { kind: "timezoneUnknown", epochMs: null };
  }

  const local = new Date(0);
  local.setUTCFullYear(year, month - 1, day);
  local.setUTCHours(hour, minute, second, milliseconds);
  const direction = offsetSign === "-" ? -1 : 1;
  const epochMs = local.getTime() - direction * (offsetHours * 60 + offsetMinutes) * 60_000;
  return Number.isFinite(epochMs) && Math.abs(epochMs) <= MAX_DATE_EPOCH_MS
    ? { kind: "zoned", epochMs }
    : { kind: "invalid", epochMs: null };
}

function openingDelimiterLocation(source: string, bomOffset: number, style: "yaml" | "toml"): ArticleStateLocation {
  const delimiter = style === "yaml" ? "---" : "+++";
  const firstLine = source.split("\n", 1)[0] ?? "";
  const delimiterOffset = Math.max(0, firstLine.indexOf(delimiter));
  return { kind: "range", from: bomOffset + delimiterOffset, to: bomOffset + delimiterOffset + delimiter.length };
}

function withoutTrailingComment(rawValue: string): string {
  let quote: "'" | '"' | null = null;
  let escaping = false;
  for (let index = 0; index < rawValue.length; index += 1) {
    const character = rawValue[index];
    if (escaping) { escaping = false; continue; }
    if (quote === '"' && character === "\\") { escaping = true; continue; }
    if (character === quote) { quote = null; continue; }
    if (!quote && (character === "'" || character === '"')) { quote = character; continue; }
    if (!quote && character === "#" && (index === 0 || /\s/.test(rawValue[index - 1]))) {
      return rawValue.slice(0, index).trim();
    }
  }
  return rawValue.trim();
}

function isJsonString(value: string): boolean {
  if (!value.startsWith('"')) return false;
  try { return typeof JSON.parse(value) === "string"; }
  catch { return false; }
}

function isYamlSingleQuotedString(value: string): boolean {
  if (value.length < 2 || value[0] !== "'" || value[value.length - 1] !== "'") return false;
  for (let index = 1; index < value.length - 1; index += 1) {
    if (value[index] !== "'") continue;
    if (value[index + 1] !== "'" || index + 1 === value.length - 1) return false;
    index += 1;
  }
  return true;
}

function isTomlSingleQuotedString(value: string): boolean {
  return /^'[^']*'$/.test(value);
}

function isYamlPlainScalar(value: string): boolean {
  const word = String.raw`[\p{L}\p{N}_./:@%+\-]+`;
  return new RegExp(`^${word}(?:[ \\t]+${word})*$`, "u").test(value);
}

function isStrictStringValue(style: "yaml" | "toml", rawValue: string, allowEmpty: boolean): boolean {
  const value = withoutTrailingComment(rawValue);
  if (!value) return allowEmpty;
  if (isJsonString(value)) return true;
  if (value.startsWith("'")) return style === "yaml" ? isYamlSingleQuotedString(value) : isTomlSingleQuotedString(value);
  return style === "yaml" && isYamlPlainScalar(value);
}

function isStrictTomlScalar(value: string): boolean {
  if (isJsonString(value) || isTomlSingleQuotedString(value)) return true;
  if (value === "true" || value === "false") return true;
  if (/^[+-]?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(value)) return true;
  return parseDate(value).kind !== "invalid";
}

function splitTomlComposite(value: string): string[] | null {
  if (!value.trim()) return [];
  const parts: string[] = [];
  let start = 0;
  let quote: "'" | '"' | null = null;
  let escaping = false;
  let squareDepth = 0;
  let curlyDepth = 0;
  for (let index = 0; index < value.length; index += 1) {
    const character = value[index];
    if (escaping) { escaping = false; continue; }
    if (quote === '"' && character === "\\") { escaping = true; continue; }
    if (character === quote) { quote = null; continue; }
    if (!quote && (character === "'" || character === '"')) { quote = character; continue; }
    if (quote) continue;
    if (character === "[") squareDepth += 1;
    else if (character === "]") squareDepth -= 1;
    else if (character === "{") curlyDepth += 1;
    else if (character === "}") curlyDepth -= 1;
    else if (character === "," && squareDepth === 0 && curlyDepth === 0) {
      const part = value.slice(start, index).trim();
      if (!part) return null;
      parts.push(part);
      start = index + 1;
    }
    if (squareDepth < 0 || curlyDepth < 0) return null;
  }
  if (quote || escaping || squareDepth !== 0 || curlyDepth !== 0) return null;
  const tail = value.slice(start).trim();
  if (!tail) return null;
  parts.push(tail);
  return parts;
}

function isStrictTomlValue(value: string, depth = 0): boolean {
  if (depth > 2) return false;
  if (value.startsWith("[")) {
    if (!value.endsWith("]")) return false;
    let inner = value.slice(1, -1).trim();
    if (!inner) return true;
    if (inner.endsWith(",")) inner = inner.slice(0, -1).trim();
    const items = splitTomlComposite(inner);
    return Boolean(items?.length) && items!.every((item) => isStrictTomlValue(item, depth + 1));
  }
  if (value.startsWith("{")) {
    if (!value.endsWith("}")) return false;
    const entries = splitTomlComposite(value.slice(1, -1));
    if (!entries) return false;
    const keys = new Set<string>();
    return entries.every((entry) => {
      const assignment = /^([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(.+)$/.exec(entry);
      if (!assignment || keys.has(assignment[1])) return false;
      keys.add(assignment[1]);
      return isStrictTomlValue(assignment[2].trim(), depth + 1);
    });
  }
  return isStrictTomlScalar(value);
}

function isStrictUnknownValue(style: "yaml" | "toml", rawValue: string): boolean {
  const value = withoutTrailingComment(rawValue);
  if (!value) return false;
  return style === "yaml"
    ? isStrictStringValue("yaml", value, false)
    : isStrictTomlValue(value);
}

function isStrictStringArray(rawValue: string): boolean {
  const value = withoutTrailingComment(rawValue);
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed) && parsed.every((item) => typeof item === "string");
  } catch {
    return false;
  }
}

function supportsFlatStatusStructure(
  source: string,
  style: "yaml" | "toml",
  bodyOffset: number,
): boolean {
  const delimiter = style === "yaml" ? "---" : "+++";
  const lines = source.slice(0, bodyOffset).split("\n").map((line) => line.replace(/\r$/, ""));
  while (lines[lines.length - 1] === "") lines.pop();
  if (lines.shift() !== delimiter) return false;
  const closing = lines.pop();
  if (closing !== delimiter && !(style === "yaml" && closing === "...")) return false;
  const tomlKeys = new Set<string>();

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim() || line.trimStart().startsWith("#")) continue;
    const field = style === "yaml"
      ? /^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*)$/.exec(line)
      : /^([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(.*)$/.exec(line);
    if (!field) return false;
    if (style === "toml") {
      if (tomlKeys.has(field[1])) return false;
      tomlKeys.add(field[1]);
    }
    const key = field[1].toLowerCase();
    if (FRONT_MATTER_FIELDS.has(key) && field[1] !== key) return false;
    if (!FRONT_MATTER_FIELDS.has(key)) {
      if (!isStrictUnknownValue(style, field[2])) return false;
      continue;
    }

    if (key === "draft" && field[2].trim() !== "true" && field[2].trim() !== "false") return false;
    if (FRONT_MATTER_ARRAY_FIELDS.has(key)) {
      if (style === "yaml" && !field[2].trim()) {
        while (index + 1 < lines.length) {
          const item = /^\s+-\s+(.+)$/.exec(lines[index + 1]);
          if (!item) break;
          if (!isStrictStringValue("yaml", item[1], false)) return false;
          index += 1;
        }
      } else if (!isStrictStringArray(field[2])) return false;
    }
    if (FRONT_MATTER_STRING_FIELDS.has(key)) {
      if (style === "toml" && key === "date" && !/^\s*["']/.test(field[2])) {
        if (parseDate(withoutTrailingComment(field[2])).kind === "invalid") return false;
      } else if (!isStrictStringValue(style, field[2], style === "yaml")) return false;
    }
  }
  return true;
}

function emptyDate(): DateProjection {
  return { kind: "absent", value: "", epochMs: null };
}

/**
 * Projects explicit local article metadata only. It performs no Git, filesystem,
 * deployment, timer, or network work and never rewrites the supplied text.
 */
export function projectArticleState(input: ArticleStateInput): ArticleStateProjection {
  const readOnly = !input.context.writable;
  const clockIsValid = validClock(input.nowEpochMs);
  const checkedAtEpochMs = clockIsValid ? input.nowEpochMs : null;
  const issues: ArticleStateIssue[] = [];

  const membership = input.context.kind === "generalDraft"
    ? { scope: "generalDraft" as const, scopeIssue: null }
    : repositoryScope(input.context);
  if (membership.scopeIssue) issues.push(membership.scopeIssue);

  const byteLength = utf8ByteLength(input.text);
  const limited = byteLength > MAX_ARTICLE_STATE_BYTES;
  if (limited) issues.push(issue("sizeLimit", null, "information"));
  if (!clockIsValid && membership.scope !== "generalDraft") {
    issues.push(issue("clockInvalid", null, "information"));
  }

  const finish = (state: ArticleStateProjection["state"], date: DateProjection): ArticleStateProjection => {
    if (membership.scope === "site") {
      issues.push(issue("publicationUnverified", { kind: "publishing" }, "information"));
    }
    if (readOnly) issues.push(issue("readOnly", null, "information"));
    return {
      state,
      scope: membership.scope,
      online: "unverified",
      readOnly,
      limited,
      date,
      checkedAtEpochMs,
      issues,
    };
  };

  if (membership.scope === "generalDraft") return finish("localOnly", emptyDate());
  if (membership.scope === "unknown" || membership.scope === "outsideSite") return finish(null, emptyDate());
  if (limited) return finish(null, emptyDate());

  const bomOffset = input.text.charCodeAt(0) === 0xfeff ? 1 : 0;
  const source = bomOffset ? input.text.slice(bomOffset) : input.text;
  const snapshot = inspectFrontMatter(source);
  if (!snapshot) {
    issues.push(issue("frontMatterMissing", { kind: "field", field: "draft" }));
    return finish(null, emptyDate());
  }
  if (snapshot.issue || !supportsFlatStatusStructure(source, snapshot.style, snapshot.bodyOffset)) {
    issues.push(issue("frontMatterInvalid", openingDelimiterLocation(source, bomOffset, snapshot.style)));
    return finish(null, emptyDate());
  }

  const fieldLocation = (field: "title" | "draft" | "date"): ArticleStateLocation => {
    const range = snapshot.fields[field];
    return range
      ? { kind: "range", from: range.from + bomOffset, to: range.to + bomOffset }
      : { kind: "field", field };
  };

  if (!snapshot.fields.title || !snapshot.values.title.trim()) {
    issues.push(issue("titleMissing", fieldLocation("title")));
  }

  let date = emptyDate();
  const dateValue = snapshot.values.date.trim();
  if (!snapshot.fields.date || !dateValue) {
    issues.push(issue("dateMissing", fieldLocation("date")));
  } else {
    const parsedDate = parseDate(dateValue);
    if (parsedDate.kind === "invalid") {
      date = { kind: "invalid", value: dateValue, epochMs: null };
      issues.push(issue("dateInvalid", fieldLocation("date")));
    } else if (parsedDate.kind === "timezoneUnknown") {
      date = { kind: "timezoneUnknown", value: dateValue, epochMs: null };
      issues.push(issue("dateTimezoneUnknown", fieldLocation("date"), "information"));
    } else if (!clockIsValid) {
      date = { kind: "invalid", value: dateValue, epochMs: parsedDate.epochMs };
    } else if (parsedDate.epochMs! > input.nowEpochMs) {
      date = { kind: "future", value: dateValue, epochMs: parsedDate.epochMs };
      issues.push(issue("dateFuture", fieldLocation("date"), "information"));
    } else {
      date = { kind: "elapsed", value: dateValue, epochMs: parsedDate.epochMs };
    }
  }

  if (!snapshot.fields.draft) {
    issues.push(issue("draftMissing", fieldLocation("draft")));
    return finish(null, date);
  }

  return finish(snapshot.values.draft ? "draft" : "ready", date);
}
