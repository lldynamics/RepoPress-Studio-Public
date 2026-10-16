import type { UiTemplate } from "../../i18n/uiMessage";
export type FrontMatterStyle = "yaml" | "toml";
export type FrontMatterField = "title" | "date" | "slug" | "permalink" | "description" | "cover" | "tags" | "categories" | "draft";

export interface FrontMatterValues {
  title: string;
  date: string;
  slug: string;
  permalink: string;
  description: string;
  cover: string;
  tags: string[];
  categories: string[];
  draft: boolean;
}

export interface FrontMatterSnapshot {
  style: FrontMatterStyle;
  values: FrontMatterValues;
  bodyOffset: number;
  issue: string | null;
  issuePresentation?: UiTemplate;
}

interface FieldEntry {
  from: number;
  to: number;
}

interface ParsedFrontMatter extends FrontMatterSnapshot {
  closingOffset: number;
  entries: Partial<Record<FrontMatterField, FieldEntry>>;
}

const STRING_FIELDS: FrontMatterField[] = ["title", "date", "slug", "permalink", "description", "cover"];
const ARRAY_FIELDS: FrontMatterField[] = ["tags", "categories"];
const KNOWN_FIELDS = new Set<FrontMatterField>([...STRING_FIELDS, ...ARRAY_FIELDS, "draft"]);

const EMPTY_VALUES: FrontMatterValues = {
  title: "",
  date: "",
  slug: "",
  permalink: "",
  description: "",
  cover: "",
  tags: [],
  categories: [],
  draft: true,
};

function lineStarts(lines: string[]): number[] {
  const starts: number[] = [];
  let offset = 0;
  for (const line of lines) {
    starts.push(offset);
    offset += line.length + 1;
  }
  return starts;
}

function decodeScalar(rawValue: string): string | null {
  const value = rawValue.trim();
  if (!value) return "";
  if (value.startsWith('"')) {
    try {
      const decoded = JSON.parse(value);
      return typeof decoded === "string" ? decoded : null;
    } catch { return null; }
  }
  if (value.startsWith("'") && value.endsWith("'")) return value.slice(1, -1).replace(/''/g, "'");
  if (/^[>|[{]/.test(value)) return null;
  return value.replace(/\s+#.*$/, "").trim();
}

function splitArray(rawValue: string): string[] | null {
  const value = rawValue.trim();
  if (!value.startsWith("[") || !value.endsWith("]")) return null;
  const inner = value.slice(1, -1).trim();
  if (!inner) return [];
  const parts: string[] = [];
  let current = "";
  let quote: "'" | '"' | null = null;
  let escaping = false;
  for (const character of inner) {
    if (escaping) { current += character; escaping = false; continue; }
    if (character === "\\" && quote === '"') { current += character; escaping = true; continue; }
    if ((character === "'" || character === '"')) {
      if (quote === character) quote = null;
      else if (!quote) quote = character;
      current += character;
      continue;
    }
    if (character === "," && !quote) { parts.push(current); current = ""; continue; }
    current += character;
  }
  if (quote) return null;
  parts.push(current);
  const decoded = parts.map(decodeScalar);
  return decoded.some((item) => item === null) ? null : decoded as string[];
}

function normalizeCollection(values: string[]): string[] {
  const seen = new Set<string>();
  return values.map((value) => value.trim()).filter((value) => {
    const key = value.toLocaleLowerCase();
    return Boolean(value) && !seen.has(key) && Boolean(seen.add(key));
  });
}

function parseInternal(source: string): ParsedFrontMatter | null {
  const lines = source.split("\n");
  const delimiter = lines[0]?.trim();
  const style: FrontMatterStyle | null = delimiter === "---" ? "yaml" : delimiter === "+++" ? "toml" : null;
  if (!style) return null;
  const closingIndex = lines.slice(1).findIndex((line) => {
    const candidate = line.trim();
    return candidate === delimiter || (style === "yaml" && candidate === "...");
  });
  if (closingIndex < 0) {
    return { style, values: { ...EMPTY_VALUES }, bodyOffset: 0, closingOffset: 0, entries: {}, issue: `找不到结束分隔符 ${delimiter}`, issuePresentation: { source: "找不到结束分隔符 {delimiter}", parameters: { delimiter } } };
  }
  const closingLine = closingIndex + 1;
  const starts = lineStarts(lines);
  const closingOffset = starts[closingLine];
  let bodyOffset = closingOffset + lines[closingLine].length;
  let skippedNewlines = 0;
  while (skippedNewlines < 2) {
    if (source.startsWith("\r\n", bodyOffset)) bodyOffset += 2;
    else if (source[bodyOffset] === "\n" || source[bodyOffset] === "\r") bodyOffset += 1;
    else break;
    skippedNewlines += 1;
  }

  const values: FrontMatterValues = { ...EMPTY_VALUES, tags: [], categories: [] };
  const entries: Partial<Record<FrontMatterField, FieldEntry>> = {};
  let issue: string | null = null;
  let issuePresentation: UiTemplate | undefined;

  for (let index = 1; index < closingLine; index += 1) {
    const line = lines[index].replace(/\r$/, "");
    if (!line.trim() || line.trimStart().startsWith("#")) continue;
    const match = style === "yaml"
      ? line.match(/^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*)$/)
      : line.match(/^([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(.*)$/);
    if (!match) continue;
    const key = match[1].toLocaleLowerCase() as FrontMatterField;
    if (!KNOWN_FIELDS.has(key)) continue;
    if (entries[key]) { issue = `字段 ${key} 重复，已保留原始文本`; issuePresentation = { source: "字段 {field} 重复，已保留原始文本", parameters: { field: key } }; break; }

    let endIndex = index + 1;
    if (style === "yaml" && ARRAY_FIELDS.includes(key) && !match[2].trim()) {
      const collected: string[] = [];
      while (endIndex < closingLine) {
        const listMatch = lines[endIndex].replace(/\r$/, "").match(/^\s+-\s+(.+)$/);
        if (!listMatch) break;
        const item = decodeScalar(listMatch[1]);
        if (item === null) { issue = `字段 ${key} 使用了暂不支持的 YAML 写法`; issuePresentation = { source: "字段 {field} 使用了暂不支持的 YAML 写法", parameters: { field: key } }; break; }
        collected.push(item);
        endIndex += 1;
      }
      values[key as "tags" | "categories"] = normalizeCollection(collected);
    } else if (ARRAY_FIELDS.includes(key)) {
      const array = splitArray(match[2]);
      if (!array) { issue = `字段 ${key} 不是可安全编辑的数组`; issuePresentation = { source: "字段 {field} 不是可安全编辑的数组", parameters: { field: key } }; break; }
      values[key as "tags" | "categories"] = normalizeCollection(array);
    } else if (key === "draft") {
      const flag = match[2].trim().toLocaleLowerCase();
      if (flag !== "true" && flag !== "false") { issue = "字段 draft 必须是 true 或 false"; issuePresentation = { source: "字段 draft 必须是 true 或 false" }; break; }
      values.draft = flag === "true";
    } else {
      const scalar = decodeScalar(match[2]);
      if (scalar === null) { issue = `字段 ${key} 使用了暂不支持的复杂写法`; issuePresentation = { source: "字段 {field} 使用了暂不支持的复杂写法", parameters: { field: key } }; break; }
      values[key as "title" | "date" | "slug" | "permalink" | "description" | "cover"] = scalar;
    }

    entries[key] = { from: starts[index], to: endIndex < lines.length ? starts[endIndex] : source.length };
    index = endIndex - 1;
  }

  return { style, values, bodyOffset, closingOffset, entries, issue, ...(issuePresentation ? { issuePresentation } : {}) };
}

export function parseFrontMatter(source: string): FrontMatterSnapshot | null {
  const parsed = parseInternal(source);
  if (!parsed) return null;
  return { style: parsed.style, values: parsed.values, bodyOffset: parsed.bodyOffset, issue: parsed.issue, ...(parsed.issuePresentation ? { issuePresentation: parsed.issuePresentation } : {}) };
}

/** Read-only presence/ranges, so defaults never masquerade as explicit fields. */
export function inspectFrontMatter(source: string): (FrontMatterSnapshot & {
  fields: Partial<Record<FrontMatterField, { from: number; to: number }>>;
}) | null {
  const parsed = parseInternal(source);
  if (!parsed) return null;
  return { style: parsed.style, values: parsed.values, bodyOffset: parsed.bodyOffset, issue: parsed.issue,
    ...(parsed.issuePresentation ? { issuePresentation: parsed.issuePresentation } : {}), fields: { ...parsed.entries } };
}

function renderField(style: FrontMatterStyle, field: FrontMatterField, value: string | string[] | boolean): string {
  const separator = style === "yaml" ? ": " : " = ";
  const rendered = Array.isArray(value)
    ? `[${normalizeCollection(value).map((item) => JSON.stringify(item)).join(", ")}]`
    : typeof value === "boolean" ? String(value) : JSON.stringify(value);
  return `${field}${separator}${rendered}\n`;
}

export function updateFrontMatterField(source: string, field: FrontMatterField, value: string | string[] | boolean): string {
  const parsed = parseInternal(source);
  if (!parsed || parsed.issue) return source;
  const rendered = renderField(parsed.style, field, value);
  const existing = parsed.entries[field];
  if (existing) return source.slice(0, existing.from) + rendered + source.slice(existing.to);
  return source.slice(0, parsed.closingOffset) + rendered + source.slice(parsed.closingOffset);
}

export function addDefaultFrontMatter(source: string, date = new Date().toISOString().slice(0, 10)): string {
  if (parseInternal(source)) return source;
  const frontMatter = [
    "---",
    'title: ""',
    `date: ${JSON.stringify(date)}`,
    'slug: ""',
    'description: ""',
    "tags: []",
    "categories: []",
    "draft: true",
    "---",
  ].join("\n");
  return `${frontMatter}\n\n${source}`;
}

export function adjustSelectionAfterFrontMatterChange(before: string, after: string, selection: { from: number; to: number }): { from: number; to: number } {
  const previous = parseFrontMatter(before);
  const next = parseFrontMatter(after);
  if (!next) return selection;
  if (!previous) {
    const shift = next.bodyOffset;
    return { from: selection.from + shift, to: selection.to + shift };
  }
  const delta = next.bodyOffset - previous.bodyOffset;
  const map = (offset: number) => offset >= previous.bodyOffset ? Math.max(next.bodyOffset, offset + delta) : Math.min(offset, next.bodyOffset);
  return { from: map(selection.from), to: map(selection.to) };
}
