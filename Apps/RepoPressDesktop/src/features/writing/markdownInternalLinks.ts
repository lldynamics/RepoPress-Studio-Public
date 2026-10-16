import type { MarkdownFileEntry, RepositorySessionSnapshot } from "../../contracts/repository";
import type { TextRange } from "./markdownWriting";
import { isInsideMarkdownFence, isInsideMarkdownInlineCode, isMarkdownEscaped, markdownFrontMatterBodyOffset } from "./markdownSyntaxContext";
export interface MarkdownInternalLinkSuggestion { path: string; label: string; url: string }
export interface InternalLinkQuery { from: number; to: number; query: string }
const safe = (n: number, len: number) => Math.max(0, Math.min(len, n));

function stripFirstPrefix(path: string, prefixes: string[]): string {
  return prefixes.find((prefix) => path.startsWith(prefix))
    ? path.slice(prefixes.find((prefix) => path.startsWith(prefix))!.length)
    : path;
}

function datedPostPath(path: string): string | null {
  const match = path.match(/^(\d{4})-(\d{2})-(\d{2})-(.+)$/);
  return match ? `${match[1]}/${match[2]}/${match[3]}/${match[4]}` : null;
}

function normalizedRouteOverride(value?: string | null): string | null {
  let path = value?.trim();
  if (!path || path.includes("://") || path.startsWith("//") || path.includes("\\")) return null;
  path = path.split("#", 1)[0].split("?", 1)[0];
  const components = path.split("/").filter(Boolean);
  if (components.includes("..")) return null;
  if (/^(?:index|readme)$/i.test(components[components.length - 1] ?? "")) components.pop();
  return components.length ? `/${components.join("/")}/` : "/";
}

export function destinationForMarkdownFile(file: MarkdownFileEntry, repository: RepositorySessionSnapshot, permalink?: string | null): string {
  const routeOverride = normalizedRouteOverride(permalink);
  if (routeOverride) return routeOverride;
  let path = file.relativePath.replace(/\\/g, "/").replace(/^\/+/, "");
  const root = repository.contentRoot?.replace(/^\/+|\/+$/g, "");
  if (root && path.startsWith(`${root}/`)) path = path.slice(root.length + 1);
  const kind = repository.siteKind.toLocaleLowerCase().replace(/[^a-z0-9]/g, "");

  if (kind === "jekyll") {
    path = stripFirstPrefix(path, ["_posts/"]);
    const dated = datedPostPath(path.replace(/\.(?:md|markdown|mdx)$/i, ""));
    if (dated) path = dated;
  } else if (kind === "hexo") {
    path = stripFirstPrefix(path, ["source/_posts/"]);
    const dated = datedPostPath(path.replace(/\.(?:md|markdown|mdx)$/i, ""));
    if (dated) path = dated;
  } else if (kind === "nextjs" || kind === "next") {
    path = `blog/${stripFirstPrefix(path, ["content/posts/", "posts/"])}`;
  } else if (kind === "zola") {
    path = stripFirstPrefix(path, ["content/posts/", "content/", "posts/"]);
  } else if (kind === "astro") {
    path = stripFirstPrefix(path, ["src/content/blog/", "content/posts/", "posts/", "blog/"]);
  } else if (kind === "vitepress") {
    path = stripFirstPrefix(path, ["docs/posts/", "docs/", "posts/"]);
  } else if (kind === "quartz") {
    path = stripFirstPrefix(path, ["content/"]);
  }

  const components = path.replace(/\.(?:md|markdown|mdx)$/i, "").replace(/^\/+|\/+$/g, "").split("/").filter(Boolean);
  if (/^(?:index|readme)$/i.test(components[components.length - 1] ?? "")) components.pop();
  return components.length ? `/${components.join("/")}/` : "/";
}

export function findInternalLinkQuery(source: string, cursor: number): InternalLinkQuery | null {
  const at = safe(cursor, source.length);
  const bodyOffset = markdownFrontMatterBodyOffset(source);
  if (at < bodyOffset) return null;
  const lineStart = source.lastIndexOf("\n", at - 1) + 1;
  const before = source.slice(lineStart, at);
  if (isInsideMarkdownFence(source, lineStart, bodyOffset, before)) return null;
  const start = before.lastIndexOf("[[");
  if (start < 0 || isMarkdownEscaped(before, start) || before.slice(start + 2).includes("]]")) return null;
  if (isInsideMarkdownInlineCode(before.slice(0, start)) || before.slice(start + 2).includes("`")) return null;
  const automaticClosingLength = source.slice(at, at + 2) === "]]" ? 2 : 0;
  return { from: lineStart + start, to: at + automaticClosingLength, query: before.slice(start + 2) };
}
export function getInternalLinkSuggestions(files: MarkdownFileEntry[], currentPath: string, repository: RepositorySessionSnapshot, query: string): MarkdownInternalLinkSuggestion[] { const q = query.trim().toLocaleLowerCase(); return files.filter((f) => f.relativePath !== currentPath).map((file, index) => ({ path: file.relativePath, label: file.displayName.replace(/\.(md|markdown|mdx)$/i, ""), url: destinationForMarkdownFile(file, repository), index })).filter((x) => !q || `${x.path} ${x.label}`.toLocaleLowerCase().includes(q)).sort((a, b) => a.label.localeCompare(b.label) || a.index - b.index).map(({ index: _, ...item }) => item); }
const linkLabel = (value: string) => value.replace(/\\/g, "\\\\").replace(/\]/g, "\\]");
const linkUrl = (value: string) => value.split("/").map((segment) => encodeURIComponent(segment).replace(/\(/g, "%28").replace(/\)/g, "%29")).join("/");
export function insertInternalLink(source: string, selection: TextRange, suggestion: MarkdownInternalLinkSuggestion): { text: string; selection: TextRange } { const from = safe(Math.min(selection.from, selection.to), source.length); const to = safe(Math.max(selection.from, selection.to), source.length); const label = linkLabel(source.slice(from, to).trim() || suggestion.label); const value = `[${label}](${linkUrl(suggestion.url)})`; return { text: source.slice(0, from) + value + source.slice(to), selection: { from: from + 1, to: from + 1 + label.length } }; }
export function applyInternalLink(source: string, query: InternalLinkQuery, suggestion: MarkdownInternalLinkSuggestion, selectedText?: string): { text: string; selection: TextRange } | null { const trigger = source.slice(query.from, query.to); if (trigger !== `[[${query.query}` && trigger !== `[[${query.query}]]`) return null; const label = linkLabel(selectedText?.trim() || suggestion.label); const value = `[${label}](${linkUrl(suggestion.url)})`; const text = source.slice(0, query.from) + value + source.slice(query.to); return { text, selection: { from: query.from + 1, to: query.from + 1 + label.length } }; }
