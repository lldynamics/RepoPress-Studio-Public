import { describe, expect, it } from "vitest";
import type { RssArticleHeader, RssFeed } from "./contracts";
import { READING_COMPLETE_THRESHOLD, countArticles, didReachReadingCompletion, feedHealth, filterAndSortArticles, insertRssReferenceAt, isRssEditorContextCurrent, normalizeReadingStyle, rssArticlePlainText, rssInspirationDraft, rssReferenceMarkdown, safeExternalHttpUrl, sanitizeArticleHtml, shouldPersistReadingProgress } from "./rssReader";

const articles: RssArticleHeader[] = [
  { id: "one", feedId: "feed-a", title: "Alpha reading", link: null, coverUrl: null, author: "Ada", publishedAt: 40, readableSummary: "A searchable summary", fetchedAt: 41, readAt: null, isStarred: true, tags: ["design"] },
  { id: "two", feedId: "feed-b", title: "Beta", link: null, coverUrl: null, author: "Ben", publishedAt: 20, readableSummary: "Other", fetchedAt: 21, readAt: 22, isStarred: false, tags: ["code"] },
  { id: "three", feedId: "feed-a", title: "Gamma", link: null, coverUrl: null, author: "Ada", publishedAt: 60, readableSummary: "Newest", fetchedAt: 61, readAt: null, isStarred: false, tags: ["code"] },
];

describe("RSS reader pure contracts", () => {
  it("filters by scope, text, author and tag then sorts deterministically", () => {
    const result = filterAndSortArticles(articles, { scope: { feed: "feed-a" }, searchText: "", unreadOnly: true, author: "Ada", tag: "code", sort: "newest" });
    expect(result.map((article) => article.id)).toEqual(["three"]);
    expect(filterAndSortArticles(articles, { scope: "all", searchText: "searchable", unreadOnly: false, author: null, tag: null, sort: "oldest" }).map((article) => article.id)).toEqual(["one"]);
  });
  it("counts unread and starred articles per feed", () => {
    const counts = countArticles(articles); expect(counts.unread).toBe(2); expect(counts.starred).toBe(1); expect(counts.unreadByFeed.get("feed-a")).toBe(2);
  });
  it("only completes reading at the 99.5 percent threshold", () => {
    expect(didReachReadingCompletion(READING_COMPLETE_THRESHOLD - 0.001)).toBe(false); expect(didReachReadingCompletion(READING_COMPLETE_THRESHOLD)).toBe(true); expect(didReachReadingCompletion(Number.NaN)).toBe(false);
  });
  it("persists progress at meaningful changes and never accepts invalid values", () => {
    expect(shouldPersistReadingProgress(.2, .205)).toBe(false); expect(shouldPersistReadingProgress(.2, .211)).toBe(true); expect(shouldPersistReadingProgress(.99, 1)).toBe(true); expect(shouldPersistReadingProgress(.2, Number.NaN)).toBe(false);
  });
  it("normalizes reader style and accepts only safe original URLs", () => {
    expect(normalizeReadingStyle({ fontSize: 99, lineHeight: 0, theme: "dark" }).fontSize).toBe(24); expect(normalizeReadingStyle({ fontSize: 99, lineHeight: 0, theme: "dark" }).lineHeight).toBe(1.35); expect(safeExternalHttpUrl("javascript:alert(1)")).toBeNull(); expect(safeExternalHttpUrl("https://example.com/article")).toContain("example.com");
  });
  it("uses a strict DOMPurify entry point for reader HTML", () => {
    const html = sanitizeArticleHtml('<article><p>safe</p><img src="https://bad.example/x"><script>alert(1)</script><a href="javascript:alert(2)" onclick="alert(3)">bad</a></article>');
    expect(html).toContain("safe"); expect(html).not.toMatch(/script|img|javascript:|onclick|src=/i);
  });
  it("keeps safe article links outside the application window", () => {
    const container = document.createElement("div");
    container.innerHTML = sanitizeArticleHtml('<p><a href="https://example.com/article" target="_self" rel="opener"><strong>Read</strong></a></p>');
    const link = container.querySelector("a")!;
    expect(link.href).toBe("https://example.com/article");
    expect(link.target).toBe("_blank");
    expect(link.rel).toBe("noopener noreferrer");
    expect(link.querySelector("strong")?.textContent).toBe("Read");
  });
  it("makes unsupported article link destinations inert", () => {
    for (const href of ["/settings", "//example.com/page", "#section", "https://user:secret@example.com", "file:///tmp/item", "data:text/html,hello", "javascript:alert(1)"]) {
      const container = document.createElement("div");
      container.innerHTML = sanitizeArticleHtml(`<a href="${href}" target="_top">Read</a>`);
      const link = container.querySelector("a")!;
      expect(link.hasAttribute("href"), href).toBe(false);
      expect(link.hasAttribute("target"), href).toBe(false);
      expect(link.textContent).toBe("Read");
    }
  });
  it("builds a plain-text, escaped RSS writing reference", () => {
    const article = { ...articles[0], summaryHtml: "<p>安全 <strong>摘录</strong></p><script>bad()</script>", contentHtml: "", webPageSnapshotHtml: null };
    expect(rssArticlePlainText(article)).toBe("安全 摘录");
    const markdown = rssReferenceMarkdown({ ...article, title: "标题 [草稿]", link: "https://example.com/post" }, "第一行\n第二行", "来源 *站点*");
    expect(markdown).toContain("> 第一行\n> 第二行");
    expect(markdown).toContain("[标题 \\[草稿\\]](https://example.com/post)");
    expect(markdown).toContain("来源 \\*站点\\*");
  });
  it("keeps HTML block boundaries and br line breaks in plain text", () => {
    const article = { ...articles[0], summaryHtml: '<article><h1>标题</h1><div>第一 <strong>段</strong><br>第二行</div><section><p>嵌套</p><p>块</p></section><script>alert(1)</script></article>', contentHtml: "", webPageSnapshotHtml: null };
    expect(rssArticlePlainText(article)).toBe("标题\n\n第一 段\n第二行\n\n嵌套\n\n块");
  });
  it("inserts an RSS reference at the cursor without replacing the draft", () => {
    expect(insertRssReferenceAt("beforeafter", 6, "> quote")).toEqual({ text: "before\n\n> quote\n\nafter", cursor: 17 });
    expect(insertRssReferenceAt("draft", 3, "   ")).toEqual({ text: "draft", cursor: 3 });
  });
  it("only inserts an asynchronous RSS reference into its original editor context", () => {
    const expected = { repositoryId: "repo", documentId: "document", editorText: "draft" };
    expect(isRssEditorContextCurrent(expected, { ...expected })).toBe(true);
    expect(isRssEditorContextCurrent(expected, { ...expected, editorText: "changed" })).toBe(false);
    expect(isRssEditorContextCurrent(expected, { ...expected, documentId: "other" })).toBe(false);
  });
  it("creates an inspiration draft with a safe RSS source and a safe-link fallback", () => {
    const article = { ...articles[0], title: "灵感 [来源]", link: "https://example.com/post", summaryHtml: "", contentHtml: "", webPageSnapshotHtml: null };
    const draft = rssInspirationDraft(article, "可延展的观点", "设计周刊");
    expect(draft).toContain('title: "灵感：灵感 [来源]"');
    expect(draft).toContain("[灵感 \\[来源\\]](https://example.com/post)");
    expect(draft).toContain("## 写作方向");
    const unsafe = rssInspirationDraft({ ...article, link: "javascript:alert(1)" }, "摘录");
    expect(unsafe).not.toMatch(/javascript:|\]\(.*alert/i);
    expect(unsafe).toContain("RSS 摘录");
  });
  it("reports retrying feeds as backing off before a general failure", () => {
    const feed = { id: "a", title: "A", url: "https://example.com/feed", siteUrl: null, iconUrl: null, addedAt: 0, lastUpdatedAt: null, etag: null, lastModified: null, lastError: "请求过多", lastIssue: null, lastRefreshAttemptAt: null, refreshFailureCount: 1, nextRetryAt: 200, lastRefreshDuration: null } satisfies RssFeed;
    expect(feedHealth(feed, 100)).toBe("backingOff"); expect(feedHealth({ ...feed, nextRetryAt: null }, 100)).toBe("failing");
  });
});
