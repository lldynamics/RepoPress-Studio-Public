import { getMarkdownDiagnostics, type MarkdownDiagnostic } from "../writing/markdownDiagnostics";
import { parseFrontMatter } from "../frontmatter/frontMatter";
import { markdownFrontMatterBodyOffset, transitionMarkdownFence, type MarkdownFenceState } from "../writing/markdownSyntaxContext";
import type { DiagnosticPresentation } from "../../i18n/uiMessage";

export interface HealthDocument { relativePath: string; displayName: string; text: string; byteSize: number; sha256: string }
export interface HealthOmission { relativePath: string | null; code: string; message: string }
export interface HealthSnapshot { documents: HealthDocument[]; totalFiles: number; scannedFiles: number; scannedBytes: number; omittedFiles: number; truncated: boolean; omissions: HealthOmission[]; warnings: string[] }
export interface HealthOverlay { relativePath: string; text: string }
export type HealthIssueSeverity = "warning" | "error";
export interface RepositoryContentHealthIssue { id: string; code: string; severity: HealthIssueSeverity; title: string; message: string; relativePath: string | null; line: number; range: { from: number; to: number }; source: "disk" | "editor" | "scan"; presentation?: DiagnosticPresentation }
export interface RepositoryContentHealthSummary { errorCount: number; warningCount: number; documentCount: number; scannedBytes: number }
export interface RepositoryContentHealthReport { issues: RepositoryContentHealthIssue[]; summary: RepositoryContentHealthSummary; partial: boolean; truncatedIssues: boolean }

const MAX_ISSUES = 5000;
const ext = /\.(?:md|markdown|mdx)$/i;
const normalize = (value: string) => value.replace(/\\/g, "/").replace(/^\.\//, "").replace(/^\/+/, "").split("/").filter(Boolean).join("/");
const key = (value: string) => decode(value).replace(/\.(?:md|markdown|mdx)$/i, "").normalize("NFKC").replace(/\s+/g, " ").toLowerCase();
function decode(value: string) { try { return decodeURIComponent(value); } catch { return value; } }
function lineStartsFor(source: string): number[] { const starts = [0]; for (let index = source.indexOf("\n"); index >= 0; index = source.indexOf("\n", index + 1)) starts.push(index + 1); return starts; }
function lineOf(starts: number[], offset: number) { let low = 0; let high = starts.length; while (low < high) { const middle = Math.floor((low + high) / 2); if (starts[middle] <= offset) low = middle + 1; else high = middle; } return Math.max(1, low); }
function maskSyntax(source: string): string {
  const chars = source.split(""); const body = markdownFrontMatterBodyOffset(source); let state: MarkdownFenceState = { marker: null, length: 0 };
  const mask = (from: number, to: number) => { for (let i = from; i < to; i++) if (chars[i] !== "\n" && chars[i] !== "\r") chars[i] = " "; };
  let from = 0;
  while (from < source.length) { const nl = source.indexOf("\n", from); const to = nl < 0 ? source.length : nl; const next = nl < 0 ? source.length : nl + 1; const line = source.slice(from, to).replace(/\r$/, "");
    if (from < body) mask(from, next); else { const was = Boolean(state.marker); const transition = transitionMarkdownFence(line, state); state = transition.state; if (was || transition.delimiterLine) mask(from, next); else { let i = from; while (i < to) { if (source[i] !== "`") { i++; continue; } let end = i + 1; while (source[end] === "`") end++; const delimiter = source.slice(i, end); const close = source.indexOf(delimiter, end); if (close < 0 || close >= to) { i = end; continue; } mask(i, close + delimiter.length); i = close + delimiter.length; } } } from = next; }
  return chars.join("");
}
function issueFromDiagnostic(item: MarkdownDiagnostic, doc: HealthDocument, source: "disk" | "editor", lineStarts: number[]): RepositoryContentHealthIssue { const code = item.id.replace(/-\d+$/, ""); return { id: `${source}:${doc.relativePath}:${item.id}`, code, severity: item.severity, title: item.title, message: item.message, relativePath: doc.relativePath, line: lineOf(lineStarts, item.range.from), range: item.range, source, ...(item.presentation ? { presentation: item.presentation } : {}) }; }
function addIssue(out: RepositoryContentHealthIssue[], item: Omit<RepositoryContentHealthIssue, "id">, idDiscriminator = "") {
  // Keep one sentinel issue beyond the display contract so truncation is provable
  // without retaining an unbounded number of findings from a large repository.
  if (out.length > MAX_ISSUES) return;
  out.push({ ...item, id: `${item.source}:${item.relativePath}:${item.code}:${item.range.from}:${item.range.to}:${idDiscriminator}` });
}

function routeVariants(path: string): string[] { const clean = normalize(path); const parts = clean.split("/"); const values = [key(clean)]; if (parts.length) values.push(key(parts[parts.length - 1])); return values.filter(Boolean); }
function targetPath(sourcePath: string, target: string): { path: string | null; unsafe: boolean } {
  const raw = decode(target.split(/[?#]/, 1)[0] ?? ""); if (!ext.test(raw) || /^[a-z][a-z0-9+.-]*:/i.test(raw) || raw.startsWith("//")) return { path: null, unsafe: false };
  const base = raw.startsWith("/") ? [] : sourcePath.split("/").slice(0, -1); const pieces = raw.replace(/\\/g, "/").split("/"); const result: string[] = [...base];
  for (const piece of pieces) { if (!piece || piece === ".") continue; if (piece === "..") { if (!result.length) return { path: null, unsafe: true }; result.pop(); } else result.push(piece); }
  return { path: normalize(result.join("/")), unsafe: false };
}

export function analyzeRepositoryContentHealth(snapshot: HealthSnapshot, overlay?: HealthOverlay): RepositoryContentHealthReport {
  const docs = snapshot.documents.map((doc) => overlay && normalize(overlay.relativePath) === normalize(doc.relativePath) ? { ...doc, text: overlay.text } : doc);
  const documentPaths = new Set(docs.map((doc) => normalize(doc.relativePath)));
  const sourceFor = (doc: HealthDocument): "disk" | "editor" => overlay && normalize(overlay.relativePath) === normalize(doc.relativePath) ? "editor" : "disk";
  const known = new Set<string>(); const parsed = new Map<string, ReturnType<typeof parseFrontMatter>>();
  for (const doc of docs) { for (const variant of routeVariants(doc.relativePath)) known.add(variant); const fm = parseFrontMatter(doc.text); parsed.set(doc.relativePath, fm); if (fm) { for (const value of [fm.values.title, fm.values.slug, fm.values.permalink]) if (typeof value === "string" && value.trim()) for (const variant of routeVariants(value)) known.add(variant); } }
  const issues: RepositoryContentHealthIssue[] = [];
  for (const doc of docs) {
    if (issues.length > MAX_ISSUES) break;
    const source = sourceFor(doc); const fm = parsed.get(doc.relativePath); const lineStarts = lineStartsFor(doc.text); const diagnostics = getMarkdownDiagnostics(doc.text, { normalizedKnownArticleTitles: known, maxIssues: MAX_ISSUES + 1 - issues.length });
    for (const item of diagnostics) addIssue(issues, issueFromDiagnostic(item, doc, source, lineStarts));
    if (issues.length > MAX_ISSUES) break;
    if (fm?.issue) addIssue(issues, { code: "frontmatter-unsafe", severity: "error", title: "Front Matter 无法安全解析", message: fm.issue, presentation: { title: { source: "Front Matter 无法安全解析" }, message: fm.issuePresentation ?? { source: "{message}", parameters: { message: fm.issue } } }, relativePath: doc.relativePath, line: 1, range: { from: 0, to: Math.min(doc.text.length, 3) }, source });
    if (fm && !fm.issue) { for (const [field, value] of [["title", fm.values.title], ["slug", fm.values.slug]] as const) if (!value.trim()) addIssue(issues, { code: `frontmatter-${field}-empty`, severity: "warning", title: `${field} 为空`, message: `Front Matter 的 ${field} 为空。`, presentation: { title: { source: "{field} 为空", parameters: { field } }, message: { source: "Front Matter 的 {field} 为空。", parameters: { field } } }, relativePath: doc.relativePath, line: 1, range: { from: 0, to: Math.min(doc.text.length, 3) }, source }); }
    const visible = maskSyntax(doc.text); const linkPattern = /(?<!!)\[[^\]\n]*\]\(\s*<?([^\s)>]+)>?(?:\s+[^)]*)?\)/g;
    for (const match of visible.matchAll(linkPattern)) { if (issues.length > MAX_ISSUES) break; const target = match[1]; const resolved = targetPath(doc.relativePath, target); if (resolved.unsafe) { const from = match.index! + match[0].indexOf(target); addIssue(issues, { code: "unsafe-relative-link", severity: "warning", title: "相对链接越过仓库根", message: `链接 ${decode(target)} 越过仓库根，未访问该路径。`, presentation: { title: { source: "相对链接越过仓库根" }, message: { source: "链接 {target} 越过仓库根，未访问该路径。", parameters: { target: decode(target) } } }, relativePath: doc.relativePath, line: lineOf(lineStarts, from), range: { from, to: from + target.length }, source }); continue; } if (!resolved.path) continue; if (!documentPaths.has(resolved.path)) { const from = match.index! + match[0].indexOf(target); addIssue(issues, { code: "missing-relative-link", severity: "error", title: "相对链接目标不存在", message: `没有找到 ${decode(target)}。`, presentation: { title: { source: "相对链接目标不存在" }, message: { source: "没有找到 {target}。", parameters: { target: decode(target) } } }, relativePath: doc.relativePath, line: lineOf(lineStarts, from), range: { from, to: from + target.length }, source }); } }
  }
  const duplicate = (field: "title" | "slug" | "permalink", severity: HealthIssueSeverity) => { const groups = new Map<string, HealthDocument[]>(); for (const doc of docs) { const value = parsed.get(doc.relativePath)?.values[field]; if (typeof value === "string" && value.trim()) groups.set(key(value), [...(groups.get(key(value)) ?? []), doc]); } for (const [value, group] of groups) if (group.length > 1) for (const doc of group) addIssue(issues, { code: `duplicate-${field}`, severity, title: `重复 ${field}`, message: `${field} “${value}” 在多个文档中重复。`, presentation: { title: { source: "重复 {field}", parameters: { field } }, message: { source: "{field} “{value}” 在多个文档中重复。", parameters: { field, value } } }, relativePath: doc.relativePath, line: 1, range: { from: 0, to: Math.min(doc.text.length, 3) }, source: sourceFor(doc) }); };
  duplicate("title", "warning"); duplicate("slug", "error"); duplicate("permalink", "error");
  const partial = snapshot.truncated || snapshot.omittedFiles > 0 || snapshot.omissions.length > 0;
  if (partial) for (const [index, omission] of (snapshot.omissions.length ? snapshot.omissions : [{ relativePath: null, code: "source-unavailable", message: "部分文件未扫描" }]).entries()) addIssue(issues, { code: "source-unavailable", severity: "warning", title: "部分源文件不可用", message: `${omission.code}: ${omission.message}`, presentation: { title: { source: "部分源文件不可用" }, message: { source: "{code}: {message}", parameters: { code: omission.code, message: omission.message }, ...(snapshot.omissions.length ? {} : { labels: { message: { source: "部分文件未扫描" } } }) } }, relativePath: omission.relativePath, line: 1, range: { from: 0, to: 0 }, source: "scan" }, String(index));
  const compareText = (left: string, right: string) => left < right ? -1 : left > right ? 1 : 0;
  issues.sort((a, b) => compareText(a.relativePath ?? "", b.relativePath ?? "") || a.range.from - b.range.from || compareText(a.code, b.code) || compareText(a.id, b.id));
  const truncatedIssues = issues.length > MAX_ISSUES; const limited = issues.slice(0, MAX_ISSUES);
  const errors = limited.filter((item) => item.severity === "error").length; const warnings = limited.length - errors;
  return { issues: limited, summary: { errorCount: errors, warningCount: warnings, documentCount: docs.length, scannedBytes: snapshot.scannedBytes }, partial, truncatedIssues };
}

export const repositoryContentHealth = analyzeRepositoryContentHealth;
export const buildRepositoryContentHealthReport = analyzeRepositoryContentHealth;
