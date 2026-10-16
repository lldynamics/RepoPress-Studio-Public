import { markdownLanguage } from "@codemirror/lang-markdown";
import type { ContentHealthSourceDocument } from "../../contracts/repository";
import type { UnpublishImpactFinding, UnpublishImpactInput, UnpublishImpactReport } from "../../contracts/unpublishImpact";
import { parseFrontMatter } from "../frontmatter/frontMatter";
import { markdownFrontMatterBodyOffset } from "../writing/markdownSyntaxContext";

const MAX_DOCUMENTS = 1_000;
const MAX_DOCUMENT_BYTES = 4 * 1024 * 1024;
const MAX_TOTAL_BYTES = 32 * 1024 * 1024;
const MAX_FINDINGS = 2_000;
const MAX_REFERENCES = 20_000;
const markdownExtension = /\.(?:md|markdown|mdx)$/i;
const bytes = (text: string) => new TextEncoder().encode(text).length;
const labelKey = (text: string) => text.replace(/\\([\[\]\\])/g, "$1").trim().replace(/\s+/g, " ").toLowerCase();

function validPath(path: string): boolean {
  return path.length > 0 && path.length <= 4096 && !/[\\\u0000-\u001f\u007f]/.test(path)
    && path.split("/").every((part) => part && part !== "." && part !== ".." && part.toLowerCase() !== ".git");
}

interface Destination { path: string; kind: "local" | "external" | "anchor" | "unsupported" }
function destination(raw: string): Destination {
  let value = raw.trim();
  if (value.startsWith("<") && value.endsWith(">")) value = value.slice(1, -1);
  value = value.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\]^_`{|}~\\])/g, "$1");
  if (!value || value.startsWith("#") || value.startsWith("?")) return { kind: "anchor", path: "" };
  if (value.length > 4096 || /[\\\u0000-\u001f\u007f{}]/.test(value) || /&(?:#\w+|\w+);/.test(value)) return { kind: "unsupported", path: "" };
  // Split before decoding: an encoded # or ? can be part of a source filename.
  value = value.split(/[?#]/, 1)[0];
  if (/%(?:2f|5c|25)/i.test(value)) return { kind: "unsupported", path: "" };
  try { value = decodeURIComponent(value); } catch { return { kind: "unsupported", path: "" }; }
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) || value.startsWith("//")) return { kind: "external", path: value };
  if (/[\\\u0000-\u001f\u007f{}]/.test(value)) return { kind: "unsupported", path: "" };
  return { kind: "local", path: value };
}

function resolvePath(sourcePath: string, path: string): string | null {
  const parts = path.startsWith("/") ? [] : sourcePath.split("/").slice(0, -1);
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") { if (!parts.length) return null; parts.pop(); }
    else { if (part.toLowerCase() === ".git") return null; parts.push(part); }
  }
  const resolved = parts.join("/");
  return validPath(resolved) ? resolved : null;
}

function routeKey(value: string): string | null {
  const parsed = destination(value);
  if (parsed.kind !== "local" || !parsed.path.startsWith("/") || parsed.path.split("/").some((part) => part === "." || part === "..")) return null;
  return parsed.path.replace(/\/+$/, "") || "/";
}

/** A bounded source-level review, never evidence that removing an article is safe.
 * Only literal relative Markdown paths are confirmed. Website routes and wiki
 * aliases remain candidates because generator configuration is not evaluated. */
export function analyzeUnpublishImpact(input: UnpublishImpactInput): UnpublishImpactReport {
  const warnings = new Set<string>();
  let partial = input.sources.truncated || input.sources.omittedFiles > 0 || input.sources.omissions.length > 0 || input.sources.warnings.length > 0;
  let omittedDocuments = input.sources.omittedFiles;
  const documents = new Map<string, ContentHealthSourceDocument>();
  const duplicates = new Set<string>();
  for (const document of input.sources.documents.slice(0, MAX_DOCUMENTS)) {
    if (!validPath(document.relativePath) || !markdownExtension.test(document.relativePath) || bytes(document.text) > MAX_DOCUMENT_BYTES) {
      partial = true; omittedDocuments++; continue;
    }
    if (documents.has(document.relativePath) || duplicates.has(document.relativePath)) {
      if (documents.delete(document.relativePath)) omittedDocuments++;
      duplicates.add(document.relativePath);
      partial = true; omittedDocuments++; continue;
    }
    documents.set(document.relativePath, document);
  }
  if (input.sources.documents.length > MAX_DOCUMENTS) {
    omittedDocuments += input.sources.documents.length - MAX_DOCUMENTS; partial = true;
  }
  const diskTarget = documents.get(input.target.relativePath);
  const targetAvailable = Boolean(diskTarget && validPath(input.target.relativePath) && bytes(input.target.text) <= MAX_DOCUMENT_BYTES);
  const targetEdited = Boolean(diskTarget && diskTarget.text !== input.target.text);
  if (diskTarget && !targetAvailable) omittedDocuments++;
  if (!targetAvailable) { partial = true; warnings.add("目标文章未完整包含在可读快照中，无法确认引用影响；请检查文件与扫描范围。"); }
  // Reserve the target first so a near-limit scan cannot silently lose its identity.
  let totalBytes = targetAvailable ? bytes(input.target.text) : 0;
  const selected: ContentHealthSourceDocument[] = [];
  if (targetAvailable && diskTarget) selected.push({ ...diskTarget, text: input.target.text });
  for (const document of documents.values()) {
    if (document.relativePath === input.target.relativePath) continue;
    const size = bytes(document.text);
    if (totalBytes + size > MAX_TOTAL_BYTES) { partial = true; omittedDocuments++; continue; }
    totalBytes += size; selected.push(document);
  }
  if (partial || omittedDocuments) warnings.add("扫描存在遗漏或达到上限，未发现的引用不能视为不存在。");
  const targetNames = new Set<string>();
  const targetRoutes = new Set<string>();
  if (targetAvailable && diskTarget) {
    targetNames.add(labelKey(input.target.relativePath.replace(markdownExtension, "")));
    targetNames.add(labelKey(input.target.relativePath.split("/").pop()!.replace(markdownExtension, "")));
    // Include saved and unsaved metadata: existing published links may still use
    // the saved permalink, while the editor is proposing a replacement.
    for (const text of new Set([diskTarget.text, input.target.text])) {
      const metadata = parseFrontMatter(text);
      if (metadata?.issue) { partial = true; warnings.add("目标文章属性无法安全解析，网站地址和标题匹配可能遗漏。"); continue; }
      if (metadata) {
        for (const name of [metadata.values.title, metadata.values.slug]) if (name.trim()) targetNames.add(labelKey(name));
        const route = routeKey(metadata.values.permalink);
        if (route) targetRoutes.add(route);
      }
    }
  }

  const findings: UnpublishImpactFinding[] = [];
  let externalLinks = 0;
  let referenceCount = 0;
  let definitionCount = 0;
  let truncated = false;
  let scannedDocuments = 0;
  function add(document: ContentHealthSourceDocument, from: number, to: number, raw: string, wiki: boolean, line: number) {
    referenceCount++;
    if (referenceCount > MAX_REFERENCES) { truncated = true; return; }
    const parsed = destination(raw);
    if (parsed.kind === "anchor") return;
    if (parsed.kind === "external") { externalLinks++; return; }
    let status: UnpublishImpactFinding["status"] = "unresolved";
    let reason = "链接无法映射到源文件，尚未确定是否引用目标文章。";
    if (parsed.kind === "local") {
      const resolved = resolvePath(document.relativePath, parsed.path);
      if (!resolved) reason = "路径越过仓库范围或包含不支持的目录，未访问该路径。";
      else if (targetAvailable && resolved === input.target.relativePath) {
        status = wiki || parsed.path.startsWith("/") ? "possible" : "confirmed";
        reason = status === "confirmed" ? "相对 Markdown 路径指向目标源文件。" : "名称与目标源文件相符，仍需核对站点链接规则。";
      } else if (targetAvailable && ((routeKey(parsed.path) && targetRoutes.has(routeKey(parsed.path)!))
        || (wiki && targetNames.has(labelKey(parsed.path.replace(markdownExtension, "")))))) {
        status = "possible"; reason = "匹配目标的固定链接、标题或名称；未验证路由、重名和重定向。";
      } else if (!wiki && !parsed.path.startsWith("/") && markdownExtension.test(parsed.path) && targetAvailable) {
        return; // A different literal source-file target is outside this impact review.
      }
    } else reason = "编码、实体或模板语法无法安全解析，需要人工核对。";
    if (findings.length >= MAX_FINDINGS) { truncated = true; return; }
    findings.push({ id: `${document.relativePath}:${from}:${to}`, documentPath: document.relativePath,
      line, range: { from, to }, target: raw, status, reason, reasonPresentation: { source: reason } });
  }

  for (const document of selected) {
    if (truncated) break;
    if (document.relativePath === input.target.relativePath) { scannedDocuments++; continue; } // Self-links do not survive removal.
    const bodyOffset = markdownFrontMatterBodyOffset(document.text);
    if (!Number.isFinite(bodyOffset)) { partial = true; omittedDocuments++; warnings.add("有文章的 Front Matter 未闭合，其正文未参与引用分析。"); continue; }
    scannedDocuments++;
    if (parseFrontMatter(document.text)?.issue) { partial = true; warnings.add("部分文章属性无法安全解析；仅审阅可识别正文。"); }
    const body = document.text.slice(bodyOffset);
    const tree = markdownLanguage.parser.parse(body);
    const definitions = new Map<string, string>();
    tree.iterate({ enter(node) {
      if (node.name !== "LinkReference") return;
      if (++definitionCount > MAX_REFERENCES) { truncated = true; return false; }
      const label = node.node.getChild("LinkLabel"); const url = node.node.getChild("URL");
      if (label && url) {
        const key = labelKey(body.slice(label.from + 1, label.to - 1));
        if (!definitions.has(key)) definitions.set(key, body.slice(url.from, url.to));
      }
      return false;
    } });
    if (truncated) break;
    const lineStarts = [0];
    for (let pos = document.text.indexOf("\n"); pos >= 0; pos = document.text.indexOf("\n", pos + 1)) lineStarts.push(pos + 1);
    const lineOf = (offset: number) => {
      let low = 0; let high = lineStarts.length;
      while (low < high) { const middle = (low + high) >>> 1; if (lineStarts[middle] <= offset) low = middle + 1; else high = middle; }
      return low;
    };
    tree.iterate({ enter(node) {
      if (truncated) return false;
      if (["CodeBlock", "FencedCode", "InlineCode", "Image", "LinkReference", "CommentBlock", "Comment"].includes(node.name)) return false;
      if (node.name === "HTMLBlock" || node.name === "HTMLTag") { partial = true; warnings.add("HTML/MDX 中的链接未解析，需要人工核对。"); return false; }
      if (node.name !== "Link" && node.name !== "Autolink") return;
      const url = node.node.getChild("URL");
      let raw: string | undefined = url ? body.slice(url.from, url.to) : undefined;
      let wiki = false;
      let from = node.from; let to = node.to;
      if (!raw && body[node.from - 1] === "[" && body[node.to] === "]") {
        wiki = true; from--; to++; raw = body.slice(node.from + 1, node.to - 1).split("|", 1)[0];
      } else if (!raw) {
        const label = node.node.getChild("LinkLabel");
        const marks = node.node.getChildren("LinkMark");
        if (marks.some((mark) => body.slice(mark.from, mark.to) === "(")) return false; // Empty destination.
        const explicit = label ? body.slice(label.from + 1, label.to - 1) : "";
        const implicit = marks.length >= 2 ? body.slice(marks[0].to, marks[1].from) : "";
        raw = definitions.get(labelKey(explicit || implicit));
      }
      if (raw !== undefined) add(document, from + bodyOffset, to + bodyOffset, raw, wiki, lineOf(from + bodyOffset));
      return false;
    } });
  }
  if (findings.some((item) => item.status === "unresolved")) partial = true;
  if (truncated) { partial = true; warnings.add("引用分析达到数量上限，后续引用或文稿未分析。"); }
  warnings.add("范围仅含当前内容目录的 Markdown 快照；HTML、复杂嵌套链接、模板、配置、重定向和生成后页面未完整覆盖。");
  warnings.add("绝对网址未核对站点归属；没有命中不代表可以安全删除或下线。此审阅不会执行下线。");
  return { targetPath: input.target.relativePath, targetAvailable, targetEdited, findings,
    scannedDocuments, omittedDocuments, externalLinks, partial, truncated, warnings: [...warnings], warningPresentations: [...warnings].map((source) => ({ source })) };
}
