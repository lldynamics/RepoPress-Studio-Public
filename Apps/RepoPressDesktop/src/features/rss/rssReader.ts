import DOMPurify from "dompurify";
import type { RssArticle, RssArticleHeader, RssFeed, RssScope, RssSortOrder } from "./contracts";

export const RSS_PAGE_SIZE = 40;
export const READING_COMPLETE_THRESHOLD = 0.995;
export const RSS_READING_STYLE_STORAGE_KEY = "repopress.rss.reading-style.v1";

export type RssReadingStyle = {
  theme: "system" | "warm" | "light" | "dark";
  fontSize: number;
  lineHeight: number;
  paragraphSpacing: number;
  fontFamily: "system" | "serif" | "songti";
  alignment: "natural" | "justify";
  codeTheme: "adaptive" | "xcode" | "solarized";
};
export const defaultReadingStyle: RssReadingStyle = { theme: "system", fontSize: 17, lineHeight: 1.65, paragraphSpacing: .82, fontFamily: "system", alignment: "natural", codeTheme: "adaptive" };

export function didReachReadingCompletion(progress: number): boolean {
  return Number.isFinite(progress) && progress >= READING_COMPLETE_THRESHOLD;
}

export function shouldPersistReadingProgress(previous: number | null, progress: number): boolean {
  if (!Number.isFinite(progress)) return false;
  const next = Math.min(1, Math.max(0, progress));
  if (previous === null || !Number.isFinite(previous)) return true;
  const normalizedPrevious = Math.min(1, Math.max(0, previous));
  return next === 0 || next === 1 || didReachReadingCompletion(next) !== didReachReadingCompletion(normalizedPrevious) || Math.abs(next - normalizedPrevious) >= .01;
}

export function normalizeReadingStyle(value: Partial<RssReadingStyle>): RssReadingStyle {
  const valid = <T extends string>(candidate: T | undefined, values: readonly T[], fallback: T) => candidate && values.includes(candidate) ? candidate : fallback;
  return {
    theme: valid(value.theme, ["system", "warm", "light", "dark"] as const, defaultReadingStyle.theme),
    fontSize: bounded(value.fontSize, 13, 24, defaultReadingStyle.fontSize),
    lineHeight: bounded(value.lineHeight, 1.35, 2.1, defaultReadingStyle.lineHeight),
    paragraphSpacing: bounded(value.paragraphSpacing, .45, 1.4, defaultReadingStyle.paragraphSpacing),
    fontFamily: valid(value.fontFamily, ["system", "serif", "songti"] as const, defaultReadingStyle.fontFamily),
    alignment: valid(value.alignment, ["natural", "justify"] as const, defaultReadingStyle.alignment),
    codeTheme: valid(value.codeTheme, ["adaptive", "xcode", "solarized"] as const, defaultReadingStyle.codeTheme),
  };
}

export function safeExternalHttpUrl(value: string | null): string | null {
  if (!value) return null;
  try { const url = new URL(value); return /^https?:$/.test(url.protocol) && Boolean(url.hostname) && !url.username && !url.password ? url.toString() : null; }
  catch { return null; }
}

export function rssArticlePlainText(article: RssArticle, fullTextPlainText = ""): string {
  const preferred = fullTextPlainText.trim();
  if (preferred) return preferred;
  const source = article.contentHtml || article.summaryHtml || article.webPageSnapshotHtml || article.readableSummary;
  if (typeof document === "undefined") return article.readableSummary.trim();
  const container = document.createElement("div");
  container.innerHTML = sanitizeArticleHtml(source);
  return htmlToReadablePlainText(container, article.readableSummary);
}

const HTML_BLOCK_TAGS = new Set(["ARTICLE", "BLOCKQUOTE", "DIV", "FIGURE", "H1", "H2", "H3", "H4", "H5", "H6", "LI", "MAIN", "OL", "P", "PRE", "SECTION", "TABLE", "TR", "UL"]);

function htmlToReadablePlainText(root: HTMLElement, fallback: string): string {
  let output = "";
  const append = (value: string) => { output += value; };
  const visit = (node: Node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      append((node.nodeValue ?? "").replace(/\s+/g, " "));
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const element = node as HTMLElement;
    if (element.tagName === "BR") { append("\n"); return; }
    const block = HTML_BLOCK_TAGS.has(element.tagName);
    if (block) append("\n\n");
    element.childNodes.forEach(visit);
    if (block) append("\n\n");
  };
  root.childNodes.forEach(visit);
  const readable = output.replace(/[ \t]*\n[ \t]*/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  return readable || fallback.trim();
}

export function rssReferenceMarkdown(article: RssArticle, excerpt: string, sourceName?: string): string {
  const title = markdownText(article.title || "RSS 文章");
  const clipped = excerpt.trim().slice(0, 900);
  const quote = clipped
    ? clipped.split(/\r?\n/).map((line) => `> ${markdownText(line)}`).join("\n")
    : "> （无可用摘录）";
  const safeLink = safeExternalHttpUrl(article.link);
  const source = safeLink ? `[${title}](${safeLink})` : title;
  const feed = sourceName?.trim() ? ` · ${markdownText(sourceName)}` : "";
  return `${quote}\n>\n> — ${source}${feed}（RSS 摘录）`;
}

export type RssEditorContext = { repositoryId: string | null; documentId: string | null; editorText: string };

/** A delayed RSS action may only change the editor that was active when it started. */
export function isRssEditorContextCurrent(expected: RssEditorContext, current: RssEditorContext): boolean {
  return expected.repositoryId === current.repositoryId
    && expected.documentId === current.documentId
    && expected.editorText === current.editorText;
}

/**
 * Local-draft fallback for platforms without a knowledge annotation/citation API.
 * The source is an ordinary, validated Markdown link rather than an invented citation ID.
 */
export function rssInspirationDraft(article: RssArticle, excerpt: string, sourceName?: string): string {
  const rawTitle = article.title.trim() || "RSS 灵感";
  const title = `灵感：${rawTitle.replace(/\s+/g, " ").slice(0, 120)}`;
  const reference = rssReferenceMarkdown(article, excerpt, sourceName);
  return [
    "---",
    `title: ${JSON.stringify(title)}`,
    'description: "来自 RSS 阅读的写作灵感"',
    "tags: [rss, inspiration]",
    "draft: true",
    "---",
    "",
    `# ${markdownText(title)}`,
    "",
    "## 来源摘录",
    "",
    reference,
    "",
    "## 写作方向",
    "",
    "- 我想回应或延展的观点：",
    "- 面向的读者与实际场景：",
    "- 可以补充的本地经验或资料：",
    "",
  ].join("\n");
}

export function insertRssReferenceAt(source: string, index: number, markdownReference: string): { text: string; cursor: number } {
  const reference = markdownReference.trim();
  if (!reference) return { text: source, cursor: Math.max(0, Math.min(source.length, index)) };
  const insertionIndex = Math.max(0, Math.min(source.length, index));
  const before = source.slice(0, insertionIndex);
  const after = source.slice(insertionIndex);
  const prefix = before.length === 0 || before.endsWith("\n\n") ? "" : before.endsWith("\n") ? "\n" : "\n\n";
  const suffix = after.length === 0 || after.startsWith("\n\n") ? "" : after.startsWith("\n") ? "\n" : "\n\n";
  const insertion = `${prefix}${reference}${suffix}`;
  return { text: `${before}${insertion}${after}`, cursor: insertionIndex + insertion.length };
}

function markdownText(value: string): string {
  return value.replace(/([\\[\]`*_{}<>])/g, "\\$1").replace(/\s+/g, " ").trim();
}

export function feedHealth(feed: RssFeed, now = Date.now() / 1000): "never" | "healthy" | "failing" | "backingOff" {
  if ((feed.nextRetryAt ?? feed.lastIssue?.retryAt ?? 0) > now) return "backingOff";
  if (feed.lastIssue || feed.lastError) return "failing";
  return feed.lastUpdatedAt ? "healthy" : "never";
}

export function countArticles(articles: RssArticleHeader[]) {
  const unreadByFeed = new Map<string, number>();
  let unread = 0;
  let starred = 0;
  for (const article of articles) {
    if (article.isStarred) starred += 1;
    if (!article.readAt) { unread += 1; unreadByFeed.set(article.feedId, (unreadByFeed.get(article.feedId) ?? 0) + 1); }
  }
  return { unread, starred, unreadByFeed };
}

export function scopeMatches(article: RssArticleHeader, scope: RssScope): boolean {
  if (scope === "all") return true;
  if (scope === "unread") return !article.readAt;
  if (scope === "starred") return article.isStarred;
  return article.feedId === scope.feed;
}

export function filterAndSortArticles(
  articles: RssArticleHeader[],
  input: { scope: RssScope; searchText: string; unreadOnly: boolean; author: string | null; tag: string | null; sort: RssSortOrder },
): RssArticleHeader[] {
  const query = input.searchText.trim().toLocaleLowerCase();
  const matches = articles.filter((article) => {
    if (!scopeMatches(article, input.scope) || (input.unreadOnly && article.readAt)) return false;
    if (input.author && article.author !== input.author) return false;
    if (input.tag && !article.tags.includes(input.tag)) return false;
    if (!query) return true;
    return [article.title, article.readableSummary, article.author ?? "", ...article.tags].join(" ").toLocaleLowerCase().includes(query);
  });
  return matches.sort((left, right) => {
    const delta = (left.publishedAt ?? left.fetchedAt) - (right.publishedAt ?? right.fetchedAt);
    return input.sort === "newest" ? -delta : delta;
  });
}

/** Strict reader HTML policy: no scripts, styles, forms, remote images, or executable URL schemes. */
export function sanitizeArticleHtml(source: string): string {
  const sanitized = DOMPurify.sanitize(source, {
    ALLOWED_TAGS: ["a", "article", "b", "blockquote", "br", "code", "del", "details", "div", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "li", "main", "mark", "ol", "p", "pre", "s", "section", "small", "span", "strong", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "u", "ul"],
    ALLOWED_ATTR: ["href", "title", "colspan", "rowspan"],
    FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form", "svg", "math", "img", "video", "audio"],
    FORBID_ATTR: ["style", "src", "srcset", "onerror", "onclick"],
    ALLOW_UNKNOWN_PROTOCOLS: false,
  }).replace(/javascript\s*:/gi, "");
  const template = document.createElement("template");
  template.innerHTML = sanitized;
  for (const link of template.content.querySelectorAll("a")) {
    const href = safeExternalHttpUrl(link.getAttribute("href"));
    if (href) {
      link.setAttribute("href", href);
      link.setAttribute("target", "_blank");
      link.setAttribute("rel", "noopener noreferrer");
    } else {
      link.removeAttribute("href");
      link.removeAttribute("target");
      link.removeAttribute("rel");
    }
  }
  return template.innerHTML;
}

function bounded(value: number | undefined, low: number, high: number, fallback: number) { return Number.isFinite(value) ? Math.min(high, Math.max(low, value as number)) : fallback; }

export function scopeLabel(scope: RssScope, feeds: RssFeed[]): string {
  if (scope === "all") return "全部文章";
  if (scope === "unread") return "未读";
  if (scope === "starred") return "稍后阅读";
  return feeds.find((feed) => feed.id === scope.feed)?.title ?? "订阅";
}
