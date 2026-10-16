import type { ImageReferenceFinding, ImageReferenceInput, ImageReferenceReport, ImageReferenceStatus } from "../../contracts/imageReferences";
import type { ContentHealthSourceDocument } from "../../contracts/repository";
import { parseFrontMatter } from "../frontmatter/frontMatter";

const MAX_DOCUMENTS = 1_000;
const MAX_DOCUMENT_BYTES = 4 * 1024 * 1024;
const MAX_TOTAL_BYTES = 32 * 1024 * 1024;
const MAX_FINDINGS = 2_000;
const MAX_IMAGES = 1_000;
const MAX_OUTPUT_CHARS = 512 * 1024;
const MAX_ALT_CHARS = 1_024;
const MAX_TARGET_CHARS = 2_048;
const MAX_PATH_CHARS = 4_096;

type Source = "disk" | "editor";
type Candidate = { relativePath: string; text: string; source: Source };
type ParsedImage = {
  offset: number;
  line: number;
  alt: string;
  target: string;
  status?: ImageReferenceStatus;
  repairable?: boolean;
  repairTarget?: { from: number; to: number; expectedText: string };
};

const scopeWarning = "仅分析 Markdown 内联和引用式图像；HTML img、wiki 嵌入、模板语法及嵌套引用块/列表代码不在范围内。含复杂 HTML/模板或异常 Front Matter 的文稿不提供单引用修复。";
const unverifiedWarning = "未验证仅表示图片清单中没有匹配项，不表示磁盘文件不存在。";
const unusedWarning = "未发现引用的图片仅限本次扫描结果，不能据此删除文件。";

export function analyzeRepositoryImageReferences(input: ImageReferenceInput): ImageReferenceReport {
  const warnings = [scopeWarning, unverifiedWarning, unusedWarning];
  let partial = Boolean(input.sources.truncated || input.sources.omittedFiles || input.sources.omissions.length || input.images.truncated || input.images.omittedFiles || input.sources.warnings.length || input.images.warnings.length);
  if (partial) warnings.push("内容源或图片清单已有省略，因此本报告不是完整仓库结论。");

  const { candidates, omitted, partial: candidatePartial } = collectCandidates(input, warnings);
  partial ||= candidatePartial;
  const imagePaths = new Set<string>();
  const suppliedImages = input.images.images.slice(0, MAX_IMAGES);
  if (input.images.images.length > MAX_IMAGES) { partial = true; warnings.push("图片清单超过安全数量上限，部分图片未参与分析。"); }
  for (const image of suppliedImages) {
    if (validRepositoryPath(image.relativePath)) imagePaths.add(image.relativePath);
    else partial = true;
  }

  const references: ImageReferenceFinding[] = [];
  const referencedPaths = new Set<string>();
  let outputChars = warnings.reduce((total, warning) => total + warning.length, 0);
  let truncated = false;
  let fieldTruncated = false;
  let scannedDocuments = 0;
  for (const candidate of candidates) {
    scannedDocuments += 1;
    const parsed = parseImages(candidate.text, MAX_FINDINGS - references.length);
    if (parsed.truncated) truncated = true;
    for (const image of parsed.images) {
      if (references.length >= MAX_FINDINGS) { truncated = true; break; }
      const altTruncated = image.alt.length > MAX_ALT_CHARS;
      const targetTruncated = image.target.length > MAX_TARGET_CHARS;
      const alt = limitText(image.alt, MAX_ALT_CHARS);
      const target = limitText(image.target, MAX_TARGET_CHARS);
      let status = image.status;
      let resolvedPath: string | null = null;
      if (targetTruncated) status = "unsupported";
      if (!status) {
        const resolution = resolveTarget(image.target, candidate.relativePath, input.repository);
        status = resolution.status;
        resolvedPath = resolution.resolvedPath;
      }
      if (resolvedPath) {
        referencedPaths.add(resolvedPath);
        if (imagePaths.has(resolvedPath)) status = "matched";
        else if (status === "matched") status = "unverified";
      }
      const finding: ImageReferenceFinding = {
        id: `image-reference:${candidate.relativePath}:${image.offset}`,
        documentPath: candidate.relativePath,
        line: image.line,
        offset: image.offset,
        alt,
        target,
        resolvedPath,
        status,
        source: candidate.source,
        repairTarget: image.repairTarget,
      };
      const characters = finding.id.length + finding.documentPath.length + finding.alt.length + finding.target.length + (finding.resolvedPath?.length ?? 0) + (finding.repairTarget ? finding.repairTarget.expectedText.length + 32 : 0) + 32;
      if (outputChars + characters > MAX_OUTPUT_CHARS) { truncated = true; break; }
      outputChars += characters;
      references.push(finding);
      if (altTruncated || targetTruncated) { truncated = true; fieldTruncated = true; }
    }
    if (truncated) break;
  }
  const unparsedDocuments = candidates.length - scannedDocuments;
  if (unparsedDocuments > 0) partial = true;
  if (truncated) { partial = true; warnings.push("引用结果达到安全上限，报告已截断。"); }
  if (fieldTruncated) warnings.push("过长的替代文本或目标已截断显示；过长目标未参与路径解析。");

  const imagesWithoutReferences: string[] = [];
  for (const image of imagePaths) {
    if (referencedPaths.has(image)) continue;
    if (outputChars + image.length > MAX_OUTPUT_CHARS) { truncated = true; partial = true; break; }
    outputChars += image.length;
    imagesWithoutReferences.push(image);
  }
  if (truncated && !warnings.includes("引用结果达到安全上限，报告已截断。")) warnings.push("输出达到安全上限，报告已截断。");
  return {
    references,
    scannedDocuments,
    omittedDocuments: input.sources.omittedFiles + omitted + unparsedDocuments,
    imageCount: suppliedImages.length,
    imagesWithoutReferences,
    partial,
    truncated,
    warnings: warnings.map((warning) => limitText(warning, 512)),
  };
}

function collectCandidates(input: ImageReferenceInput, warnings: string[]) {
  const disk = new Map<string, Candidate>();
  const suppliedDocuments = input.sources.documents.slice(0, MAX_DOCUMENTS);
  let omitted = input.sources.documents.length - suppliedDocuments.length;
  let partial = omitted > 0;
  for (const document of suppliedDocuments) {
    if (!validDocument(document)) { omitted += 1; partial = true; continue; }
    if (disk.has(document.relativePath)) { omitted += 1; partial = true; continue; }
    disk.set(document.relativePath, { relativePath: document.relativePath, text: document.text, source: "disk" });
  }
  let overlay: Candidate | null = null;
  if (input.overlay) {
    if (validRepositoryPath(input.overlay.relativePath)) {
      const replaced = disk.delete(input.overlay.relativePath);
      if (typeof input.overlay.text === "string" && byteLength(input.overlay.text) <= MAX_DOCUMENT_BYTES) {
        overlay = { relativePath: input.overlay.relativePath, text: input.overlay.text, source: "editor" };
      } else {
        if (replaced) omitted += 1;
        partial = true;
        warnings.push("编辑器覆盖内容超过单篇字节上限，对应磁盘文章已省略。");
      }
    } else {
      partial = true;
      warnings.push("编辑器覆盖内容不符合路径或大小限制，未参与分析。");
    }
  }
  const ordered = overlay ? [overlay, ...disk.values()] : [...disk.values()];
  const candidates: Candidate[] = [];
  let totalBytes = 0;
  for (const candidate of ordered) {
    const size = byteLength(candidate.text);
    if (candidates.length >= MAX_DOCUMENTS || size > MAX_DOCUMENT_BYTES || totalBytes + size > MAX_TOTAL_BYTES) {
      omitted += 1;
      partial = true;
      continue;
    }
    candidates.push(candidate);
    totalBytes += size;
  }
  if (partial) warnings.push("部分文章超过分析数量或字节上限，报告为局部结果。");
  return { candidates, omitted, partial };
}

function validDocument(document: ContentHealthSourceDocument): boolean {
  return validRepositoryPath(document.relativePath) && typeof document.text === "string" && byteLength(document.text) <= MAX_DOCUMENT_BYTES;
}

function validRepositoryPath(path: string): boolean {
  if (!path || path.length > MAX_PATH_CHARS || /[\\\u0000-\u001f\u007f]/u.test(path)) return false;
  const segments = path.split("/");
  return segments.every((segment) => segment.length > 0 && segment !== "." && segment !== ".." && segment.toLowerCase() !== ".git");
}

function byteLength(value: string) { return new TextEncoder().encode(value).length; }
function limitText(value: string, maximum: number) { return value.length <= maximum ? value : value.slice(0, maximum); }

function parseImages(source: string, maximum: number): { images: ParsedImage[]; truncated: boolean } {
  const masked = maskIgnoredMarkdown(source);
  const definitions = parseDefinitions(masked);
  const repairBodyOffset = repairableBodyOffset(source);
  const lineStarts = [0];
  for (let index = 0; index < source.length; index += 1) if (source[index] === "\n") lineStarts.push(index + 1);
  const results: ParsedImage[] = [];
  for (let index = 0; index < masked.length; index += 1) {
    if (masked[index] !== "!" || masked[index + 1] !== "[" || escapedAt(masked, index)) continue;
    if (masked[index + 2] === "[") continue;
    const altEnd = closingBracket(masked, index + 2, "]");
    if (altEnd < 0) continue;
    const alt = unescapeMarkdown(source.slice(index + 2, altEnd));
    const line = lineAt(lineStarts, index);
    let cursor = altEnd + 1;
    if (masked[cursor] === "(") {
      const parsed = parseInlineDestination(masked, source, cursor + 1);
      if (parsed) {
        if (results.length >= maximum) return { images: results, truncated: true };
        results.push({
          offset: index,
          line,
          alt,
          target: parsed.target,
          repairTarget: parsed.repairable && repairBodyOffset !== null && index >= repairBodyOffset && repairableDestination(parsed.target)
            ? { from: parsed.targetStart, to: parsed.targetEnd, expectedText: source.slice(parsed.targetStart, parsed.targetEnd) }
            : undefined,
        }); index = parsed.end;
      }
      continue;
    }
    let label = "";
    if (masked[cursor] === "[") {
      const end = closingBracket(masked, cursor + 1, "]");
      if (end < 0) continue;
      label = masked.slice(cursor + 1, end) || alt;
      cursor = end;
    } else {
      label = alt;
      cursor = altEnd;
    }
    const target = definitions.get(normalizeLabel(label));
    if (results.length >= maximum) return { images: results, truncated: true };
    results.push(target ? { offset: index, line, alt, target } : { offset: index, line, alt, target: `[${label}]`, status: "unsupported" });
    index = cursor;
  }
  return { images: results, truncated: false };
}

function parseDefinitions(masked: string): Map<string, string> {
  const definitions = new Map<string, string>();
  let lineStart = 0;
  while (lineStart < masked.length) {
    const lineEnd = masked.indexOf("\n", lineStart);
    const end = lineEnd < 0 ? masked.length : lineEnd;
    const line = masked.slice(lineStart, end).replace(/\r$/, "");
    const match = /^[ \t]{0,3}\[([^\]]+)\]\s*:\s*(.*)$/u.exec(line);
    if (match) {
      const target = definitionTarget(match[2]);
      if (target !== null && !definitions.has(normalizeLabel(match[1]))) definitions.set(normalizeLabel(match[1]), target);
    }
    lineStart = end + 1;
  }
  return definitions;
}

function definitionTarget(value: string): string | null {
  const trimmed = value.trimStart();
  if (!trimmed) return null;
  if (trimmed.startsWith("<")) {
    const end = trimmed.indexOf(">");
    return end > 0 ? trimmed.slice(1, end) : null;
  }
  const match = /^(\S+)/u.exec(trimmed);
  return match ? unescapeMarkdown(match[1]) : null;
}

function parseInlineDestination(masked: string, source: string, start: number): { target: string; end: number; targetStart: number; targetEnd: number; repairable: boolean } | null {
  let cursor = start;
  while (/\s/u.test(masked[cursor] ?? "")) cursor += 1;
  if (masked[cursor] === "<") {
    const close = masked.indexOf(">", cursor + 1);
    if (close < 0) return null;
    const end = masked.indexOf(")", close + 1);
    return end < 0 ? null : { target: unescapeMarkdown(source.slice(cursor + 1, close)), end, targetStart: cursor + 1, targetEnd: close, repairable: confirmedInlineTail(masked, close + 1, end) };
  }
  const targetStart = cursor;
  let depth = 0;
  for (; cursor < masked.length; cursor += 1) {
    const character = masked[cursor];
    if (character === "\\") { cursor += 1; continue; }
    if (character === "(" ) { depth += 1; continue; }
    if (character === ")") {
      if (depth === 0) return { target: unescapeMarkdown(source.slice(targetStart, cursor).trim()), end: cursor, targetStart, targetEnd: cursor, repairable: true };
      depth -= 1;
      continue;
    }
    if (/\s/u.test(character) && depth === 0) {
      const target = unescapeMarkdown(source.slice(targetStart, cursor));
      const end = masked.indexOf(")", cursor + 1);
      return end < 0 ? null : { target, end, targetStart, targetEnd: cursor, repairable: confirmedInlineTail(masked, cursor, end) };
    }
  }
  return null;
}

/** Repair is narrower than P22's diagnostic parser: a title must be one of
 * the complete Markdown title forms, and no unrecognised text may sit before
 * the enclosing destination bracket. */
function confirmedInlineTail(masked: string, start: number, end: number): boolean {
  let cursor = start;
  while (/\s/u.test(masked[cursor] ?? "")) cursor += 1;
  if (cursor === end) return true;
  const quote = masked[cursor];
  if (quote === '"' || quote === "'") {
    cursor += 1;
    while (cursor < end) {
      if (masked[cursor] === "\\") { cursor += 2; continue; }
      if (masked[cursor] === quote) {
        cursor += 1;
        while (/\s/u.test(masked[cursor] ?? "")) cursor += 1;
        return cursor === end;
      }
      cursor += 1;
    }
    return false;
  }
  if (quote !== "(") return false;
  let depth = 1;
  for (cursor += 1; cursor < end; cursor += 1) {
    if (masked[cursor] === "\\") { cursor += 1; continue; }
    if (masked[cursor] === "(") depth += 1;
    else if (masked[cursor] === ")" && --depth === 0) {
      cursor += 1;
      while (/\s/u.test(masked[cursor] ?? "")) cursor += 1;
      return cursor === end;
    }
  }
  return false;
}

function repairableDestination(value: string): boolean {
  return Boolean(value.trim()) && !/[\r\n]|\{\{|\}\}|<%|%>|\[\[|\]\]/u.test(value);
}

/** P22's report keeps its historical diagnostic coverage. Repair instead
 * fails closed for a malformed preamble and documents with syntax containers
 * whose Markdown ownership would require a complete parser. */
function repairableBodyOffset(source: string): number | null {
  const bom = source.charCodeAt(0) === 0xfeff ? 1 : 0;
  const frontMatter = parseFrontMatter(source.slice(bom));
  if (frontMatter?.issue) return null;
  const bodyOffset = bom + (frontMatter?.bodyOffset ?? 0);
  const body = source.slice(bodyOffset);
  if (/<\/?[A-Za-z][^>]*>|\{\{|\}\}|<%|%>/u.test(body)) return null;
  // P22 intentionally keeps reporting these constructs. Repair cannot safely
  // distinguish quote/list code containers without a full block parser.
  if (/^[ \t]{0,3}>|^[ \t]*(?:[-+*]|\d+[.)])\s+(?:`{3,}|~{3,}| {4,}|\t)/mu.test(body)) return null;
  return bodyOffset;
}

function closingBracket(value: string, start: number, close: string): number {
  let depth = 0;
  for (let index = start; index < value.length; index += 1) {
    if (value[index] === "\\") { index += 1; continue; }
    if (value[index] === "[") depth += 1;
    else if (value[index] === close) { if (depth === 0) return index; depth -= 1; }
  }
  return -1;
}

function escapedAt(value: ArrayLike<string>, index: number): boolean {
  let slashes = 0;
  for (let cursor = index - 1; cursor >= 0 && value[cursor] === "\\"; cursor -= 1) slashes += 1;
  return slashes % 2 === 1;
}

function normalizeLabel(value: string) { return unescapeMarkdown(value).trim().replace(/\s+/gu, " ").toLowerCase(); }
function unescapeMarkdown(value: string) { return value.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/gu, "$1"); }
function lineAt(starts: number[], offset: number) {
  let low = 0;
  let high = starts.length;
  while (low + 1 < high) {
    const middle = Math.floor((low + high) / 2);
    if (starts[middle] <= offset) low = middle;
    else high = middle;
  }
  return low + 1;
}

function maskIgnoredMarkdown(source: string): string {
  const output = source.split("");
  const erase = (from: number, to: number) => { for (let index = from; index < to; index += 1) if (output[index] !== "\n" && output[index] !== "\r") output[index] = " "; };
  let lineStart = 0;
  let fence: string | null = null;
  let frontMatter = source.startsWith("---\n") || source.startsWith("---\r\n");
  while (lineStart < source.length) {
    const lineEnd = source.indexOf("\n", lineStart);
    const end = lineEnd < 0 ? source.length : lineEnd + 1;
    const line = source.slice(lineStart, lineEnd < 0 ? source.length : lineEnd).replace(/\r$/, "");
    if (frontMatter) {
      erase(lineStart, end);
      if (lineStart !== 0 && /^(---|\.\.\.)\s*$/u.test(line)) frontMatter = false;
    } else {
      const match = /^(?: {0,3})(`{3,}|~{3,})/u.exec(line);
      if (fence) {
        erase(lineStart, end);
        const close = new RegExp(`^ {0,3}${fence[0]}{${fence.length},}[ \\t]*$`, "u");
        if (close.test(line)) fence = null;
      } else if (/^(?: {4}|\t)/u.test(line)) {
        erase(lineStart, end);
      } else if (match) { fence = match[1]; erase(lineStart, end); }
    }
    lineStart = end;
  }
  for (let index = 0; index < output.length;) {
    if (startsWithChars(output, "<!--", index)) {
      const end = markerEnd(output, "-->", index + 4);
      const finish = end < 0 ? output.length : end + 3;
      erase(index, finish); index = finish; continue;
    }
    if (output[index] === "`" && !escapedAt(output, index)) {
      let run = 1; while (output[index + run] === "`") run += 1;
      const end = codeDelimiterEnd(output, index + run, run);
      if (end >= 0) { erase(index, end + run); index = end + run; continue; }
      index += run;
      continue;
    }
    index += 1;
  }
  return output.join("");
}

function codeDelimiterEnd(source: ArrayLike<string>, start: number, run: number): number {
  for (let index = start; index < source.length; index += 1) {
    if (source[index] !== "`") continue;
    let length = 1;
    while (source[index + length] === "`") length += 1;
    if (length === run) return index;
    index += length - 1;
  }
  return -1;
}

function startsWithChars(value: ArrayLike<string>, marker: string, start: number): boolean {
  for (let index = 0; index < marker.length; index += 1) if (value[start + index] !== marker[index]) return false;
  return true;
}

function markerEnd(value: ArrayLike<string>, marker: string, start: number): number {
  for (let index = start; index <= value.length - marker.length; index += 1) if (startsWithChars(value, marker, index)) return index;
  return -1;
}

function resolveTarget(target: string, documentPath: string, repository: ImageReferenceInput["repository"]): { status: ImageReferenceStatus; resolvedPath: string | null } {
  const value = target.trim();
  if (!value || value.length > MAX_TARGET_CHARS || /\{\{|\}\}|<%|%>|\[\[|\]\]/u.test(value)) return { status: "unsupported", resolvedPath: null };
  if (/^(https?:)?\/\//iu.test(value)) return { status: "external", resolvedPath: null };
  if (/^data:/iu.test(value)) return { status: "unsupported", resolvedPath: null };
  if (/^[a-z][a-z0-9+.-]*:/iu.test(value)) return { status: "unsupported", resolvedPath: null };
  const local = value.split(/[?#]/u, 1)[0];
  if (!local || /%2f|%5c/iu.test(local)) return { status: "unsafe", resolvedPath: null };
  let decoded: string;
  try { decoded = decodeURIComponent(local); } catch { return { status: "unsafe", resolvedPath: null }; }
  if (/\\|[\u0000-\u001f\u007f]/u.test(decoded)) return { status: "unsafe", resolvedPath: null };
  if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/iu.test(decoded)) return { status: "unsupported", resolvedPath: null };
  const resolvedPath = decoded.startsWith("/") ? resolvePublicPath(decoded.slice(1), repository) : resolveRelativePath(decoded, documentPath);
  if (!resolvedPath) return { status: "unsafe", resolvedPath: null };
  return { status: "matched", resolvedPath };
}

function resolvePublicPath(path: string, repository: ImageReferenceInput["repository"]): string | null {
  const root = publicRoot(repository);
  const segments = safeSegments(path);
  if (!segments) return null;
  if (root === "assets/") { if (segments[0] !== "assets") return null; return `assets/${segments.slice(1).join("/")}`; }
  if (root === "attachments/") { if (segments[0] !== "attachments") return null; return `attachments/${segments.slice(1).join("/")}`; }
  return `${root}${segments.join("/")}`;
}

function resolveRelativePath(path: string, documentPath: string): string | null {
  const base = documentPath.split("/").slice(0, -1);
  const segments = path.split("/");
  for (const segment of segments) {
    if (!segment || segment === ".") continue;
    if (segment === "..") { if (!base.length) return null; base.pop(); continue; }
    if (!safeSegments(segment)) return null;
    base.push(segment);
  }
  const resolved = base.join("/");
  return validRepositoryPath(resolved) ? resolved : null;
}

function safeSegments(path: string): string[] | null {
  const segments = path.split("/");
  if (!segments.length || segments.some((segment) => !segment || segment === "." || segment === ".." || segment.toLowerCase() === ".git" || /\\|[\u0000-\u001f\u007f]/u.test(segment))) return null;
  return segments;
}

function publicRoot(repository: ImageReferenceInput["repository"]): string {
  switch (repository.siteKind) {
    case "hugo": case "zola": return "static/";
    case "astro": case "nextjs": return "public/";
    case "vitepress": return "docs/public/";
    case "hexo": return "source/";
    case "jekyll": return "assets/";
    case "jekyll-or-hexo": return repository.contentRoot === "source/_posts" ? "source/" : "assets/";
    case "quartz": return "content/";
    case "foam": return "attachments/";
    default: return "static/";
  }
}
