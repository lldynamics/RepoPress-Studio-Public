import { exitActivity } from "../../platform/exitActivity";
import { invoke } from "@tauri-apps/api/core";
import type { PlanTextTranslationRequest, TextTranslationResult } from "../../contracts/repository";
import type { RssArticle, RssArticleHeader, RssArticlePage, RssBackupInspection, RssFeed, RssFullTextRecord, RssGateway, RssHighlight, RssHistoryCheckpointSummary, RssHistoryJob, RssOfflineTranslationCacheStatus, RssOfflineTranslationCleanup, RssOfflineTranslationRecord, RssOpmlExecution, RssOpmlReview, RssPreferences, RssPruneSummary, RssReadingProgress, RssRefreshSummary, RssRemoveFeedResult, RssScope, RssSnapshot } from "./contracts";
import { filterAndSortArticles } from "./rssReader";

type Invoke = <T>(command: string, args?: object) => Promise<T>;
const command = {
  snapshot: "rss_snapshot", discover: "rss_discover", addFeed: "rss_add_feed", updateFeedUrl: "rss_update_feed_url", removeFeed: "rss_remove_feed",
  refreshFeed: "rss_refresh_feed", refreshAll: "rss_refresh_all", listArticles: "rss_list_articles", getArticle: "rss_get_article",
  updateArticleState: "rss_update_article_state", markAllRead: "rss_mark_all_read", importOpml: "rss_import_opml", exportOpml: "rss_export_opml",
  getPreferences: "rss_get_preferences", updatePreferences: "rss_update_preferences", prune: "rss_prune", fetchFullText: "rss_fetch_full_text", fetchCover: "rss_fetch_cover", listHighlights: "rss_list_highlights", saveHighlight: "rss_save_highlight", deleteHighlight: "rss_delete_highlight", getReadingProgress: "rss_get_reading_progress", saveReadingProgress: "rss_save_reading_progress", undoRemoveFeed: "rss_undo_remove_feed", undoMarkAllRead: "rss_undo_mark_all_read", exportBackup: "rss_export_backup", inspectBackup: "rss_inspect_backup", restoreBackup: "rss_restore_backup",
  getOfflineTranslation: "rss_get_offline_translation", saveOfflineTranslation: "rss_save_offline_translation", deleteOfflineTranslation: "rss_delete_offline_translation", offlineTranslationCacheStatus: "rss_offline_translation_cache_status", pruneOfflineTranslations: "rss_prune_offline_translations", clearOfflineTranslations: "rss_clear_offline_translations",
  reviewOpml: "rss_review_opml", executeOpml: "rss_execute_opml", historyDiscover: "rss_history_discover", historyResumeDiscovery: "rss_history_resume_discovery", historyCancelDiscovery: "rss_history_cancel_discovery", historyStatus: "rss_history_status", historyList: "rss_history_list", historyClear: "rss_history_clear", historyPrepareRetry: "rss_history_prepare_retry", historyStep: "rss_history_step", historyPause: "rss_history_pause",
} as const;

export function createRssGateway(tauriInvoke?: Invoke): RssGateway {
  const call: Invoke = (name, args) => exitActivity.run(() => invoke(name, args as never));
  return tauriInvoke || isTauriRuntime() ? new TauriRssGateway(tauriInvoke ?? call) : new BrowserDemoRssGateway();
}

class TauriRssGateway implements RssGateway {
  constructor(private readonly call: Invoke) {}
  snapshot() { return this.call<RssSnapshot>(command.snapshot); }
  discover(homepageUrl: string) { return this.call<string[]>(command.discover, { homepageUrl }); }
  addFeed(input: { url: string; title?: string | null; siteUrl?: string | null }) { return this.call<RssFeed>(command.addFeed, input); }
  updateFeedUrl(feedId: string, newUrl: string) { return this.call<RssFeed>(command.updateFeedUrl, { feedId, newUrl }); }
  removeFeed(feedId: string) { return this.call<RssRemoveFeedResult | void>(command.removeFeed, { feedId }); }
  refreshFeed(feedId: string, force = false) { return this.call<RssRefreshSummary>(command.refreshFeed, { feedId, force }); }
  refreshAll(force = false) { return this.call<RssRefreshSummary>(command.refreshAll, { force }); }
  listArticles(input: { scope: RssScope; searchText: string; unreadOnly: boolean; author: string | null; tag: string | null; sort: "newest" | "oldest"; offset: number; limit: number }) { return this.call<RssArticlePage>(command.listArticles, input); }
  getArticle(articleId: string) { return this.call<RssArticle | null>(command.getArticle, { articleId }); }
  updateArticleState(input: { articleId: string; readAt?: number | null; isStarred?: boolean; tags?: string[] }) {
    const hasReadChange = Object.prototype.hasOwnProperty.call(input, "readAt");
    return this.call<RssArticleHeader>(command.updateArticleState, {
      articleId: input.articleId,
      ...(hasReadChange ? { read: input.readAt !== null } : {}),
      ...(typeof input.isStarred === "boolean" ? { isStarred: input.isStarred } : {}),
      ...(input.tags ? { tags: input.tags } : {}),
    });
  }
  markAllRead(input: { scope: RssScope; articleIds?: string[]; searchText?: string; unreadOnly?: boolean; author?: string | null; tag?: string | null }) { return this.call<number | { changedCount: number; undoToken: string | null }>(command.markAllRead, input); }
  undoMarkAllRead(undoToken: string) { return this.call<void>(command.undoMarkAllRead, { undoToken }); }
  undoRemoveFeed(undoToken: string) { return this.call<void>(command.undoRemoveFeed, { undoToken }); }
  fetchFullText(articleId: string, force: boolean) { return this.call<RssFullTextRecord>(command.fetchFullText, { articleId, force }); }
  fetchCover(articleId: string) { return this.call<string | null>(command.fetchCover, { articleId }); }
  listHighlights(articleId: string) { return this.call<RssHighlight[]>(command.listHighlights, { articleId }); }
  saveHighlight(input: { id?: string | null; articleId: string; text: string; note: string; tags: string[] }) { return this.call<RssHighlight>(command.saveHighlight, input); }
  deleteHighlight(highlightId: string) { return this.call<void>(command.deleteHighlight, { highlightId }); }
  getReadingProgress(articleId: string) { return this.call<RssReadingProgress | null>(command.getReadingProgress, { articleId }); }
  saveReadingProgress(input: { articleId: string; progress: number; revision: number }) { return this.call<RssReadingProgress>(command.saveReadingProgress, input); }
  importOpml(opml: string) { return this.call<{ importedCount: number; skippedCount: number }>(command.importOpml, { opml }); }
  exportOpml() { return this.call<string>(command.exportOpml); }
  reviewOpml(input: { direction: "import" | "export"; opml?: string }) { return this.call<RssOpmlReview>(command.reviewOpml, { input }); }
  executeOpml(input: { direction: "import" | "export"; opml?: string; fingerprint: string; action: "redact" | "exclude" }) { return this.call<RssOpmlExecution>(command.executeOpml, { input }); }
  historyDiscover(input: { feedId: string; directoryUrl: string; maxPages: number; maxArticles: number; discoveryId: string; fillExisting?: boolean }) { return this.call<RssHistoryJob>(command.historyDiscover, { input }); }
  historyResumeDiscovery(input: { jobId: string; discoveryId: string; maxPages: number; maxArticles: number }) { return this.call<RssHistoryJob>(command.historyResumeDiscovery, { input }); }
  historyCancelDiscovery(discoveryId: string) { return this.call<void>(command.historyCancelDiscovery, { discoveryId }); }
  historyStatus(feedId: string) { return this.call<RssHistoryJob | null>(command.historyStatus, { feedId }); }
  historyList() { return this.call<RssHistoryCheckpointSummary[]>(command.historyList); }
  historyClear(jobId: string) { return this.call<void>(command.historyClear, { jobId }); }
  historyPrepareRetry(input: { jobId: string; maxArticles: number }) { return this.call<RssHistoryJob>(command.historyPrepareRetry, { input }); }
  historyStep(input: { jobId: string; retryFailures?: boolean }) { return this.call<RssHistoryJob>(command.historyStep, { input }); }
  historyPause(jobId: string) { return this.call<RssHistoryJob>(command.historyPause, { jobId }); }
  getPreferences() { return this.call<RssPreferences>(command.getPreferences); }
  updatePreferences(preferences: RssPreferences) { return this.call<RssPreferences>(command.updatePreferences, { preferences }); }
  prune() { return this.call<RssPruneSummary>(command.prune); }
  exportBackup() { return this.call<string>(command.exportBackup); }
  inspectBackup(backupText: string) { return this.call<RssBackupInspection>(command.inspectBackup, { backupText }); }
  restoreBackup(backupText: string) { return this.call<RssBackupInspection>(command.restoreBackup, { backupText }); }
  getOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest }) { return this.call<RssOfflineTranslationRecord | null>(command.getOfflineTranslation, { request: { articleId: input.articleId, ...input.request } }); }
  saveOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest; result: TextTranslationResult }) { return this.call<RssOfflineTranslationRecord>(command.saveOfflineTranslation, { request: { articleId: input.articleId, ...input.request }, result: input.result }); }
  deleteOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest }) { return this.call<void>(command.deleteOfflineTranslation, { request: { articleId: input.articleId, ...input.request } }); }
  offlineTranslationCacheStatus() { return this.call<RssOfflineTranslationCacheStatus>(command.offlineTranslationCacheStatus); }
  pruneOfflineTranslations() { return this.call<RssOfflineTranslationCleanup>(command.pruneOfflineTranslations); }
  clearOfflineTranslations(feedId?: string | null) { return this.call<RssOfflineTranslationCleanup>(command.clearOfflineTranslations, { feedId: feedId ?? null }); }
}

class BrowserDemoRssGateway implements RssGateway {
  private feeds = seedFeeds();
  private articles = seedArticles();
  private preferences: RssPreferences = { automaticPruningEnabled: true, retentionDays: 90, feedBodyOfflineCacheEnabled: true, privateNetworkAccessEnabled: false, backgroundRefreshEnabled: true, backgroundRefreshIntervalMinutes: 30, automaticMarkReadAtEndEnabled: true, automaticFullTextExtractionEnabled: false, offlineCacheFullTextOnRefreshEnabled: false, remoteImagesEnabled: false, offlineTranslationCacheEnabled: false, offlineTranslationRetentionDays: 30, offlineTranslationMaxMiB: 100, automaticLocalPretranslationOnRefreshEnabled: false };
  private fullTexts = new Map<string, RssFullTextRecord>();
  private highlights = new Map<string, RssHighlight>();
  private progress = new Map<string, RssReadingProgress>();
  private removed = new Map<string, { feeds: RssFeed[]; articles: RssArticle[] }>();
  private readUndos = new Map<string, Map<string, number | null>>();
  private offlineTranslations = new Map<string, RssOfflineTranslationRecord>();
  private opmlReviews = new Map<string, { direction: "import" | "export"; opml: string; review: RssOpmlReview }>();
  async snapshot(): Promise<RssSnapshot> {
    const articles = this.headers();
    const counts = countSnapshotArticles(articles);
    return { feeds: this.feeds, articles, ...counts, authors: [...new Set(articles.map((article) => article.author).filter((value): value is string => Boolean(value)))].sort(), tags: [...new Set(articles.flatMap((article) => article.tags))].sort(), statusMessage: "浏览器演示使用内存 RSS 数据。", errorMessage: null };
  }
  async discover(homepageUrl: string) {
    const url = safeHttpUrl(homepageUrl);
    return [`${url.origin}/feed.xml`, `${url.origin}/atom.xml`];
  }
  async addFeed(input: { url: string; title?: string | null; siteUrl?: string | null }) {
    const url = safeHttpUrl(input.url).toString();
    const existing = this.feeds.find((feed) => feed.url === url); if (existing) return existing;
    const now = nowSeconds(); const host = new URL(url).hostname;
    const feed: RssFeed = { id: `demo-feed-${crypto.randomUUID()}`, title: input.title?.trim() || host, url, siteUrl: input.siteUrl ?? null, iconUrl: null, addedAt: now, lastUpdatedAt: null, etag: null, lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: null, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: null };
    this.feeds = [...this.feeds, feed]; return feed;
  }
  async updateFeedUrl(feedId: string, newUrl: string) {
    const url = safeHttpUrl(newUrl).toString();
    if (this.feeds.some((feed) => feed.id !== feedId && feed.url === url)) throw new Error("该地址已经在订阅列表中。");
    const feed = this.feed(feedId); const next = { ...feed, url, lastUpdatedAt: null, etag: null, lastModified: null, lastError: null, lastIssue: null, nextRetryAt: null };
    this.feeds = this.feeds.map((entry) => entry.id === feedId ? next : entry); return next;
  }
  async removeFeed(feedId: string) { const feed = this.feed(feedId); const removedArticles = this.articles.filter((article) => article.feedId === feedId); const undoToken = `remove-${crypto.randomUUID()}`; this.removed.set(undoToken, { feeds: [feed], articles: removedArticles }); this.deleteOfflineTranslationsForArticles(new Set(removedArticles.map((article) => article.id))); this.feeds = this.feeds.filter((entry) => entry.id !== feedId); this.articles = this.articles.filter((article) => article.feedId !== feedId); return { undoToken }; }
  async refreshFeed(feedId: string) { const feed = this.feed(feedId); const now = nowSeconds(); this.feeds = this.feeds.map((entry) => entry.id === feedId ? { ...entry, lastUpdatedAt: now, lastRefreshAttemptAt: now, lastRefreshDuration: 0.12, lastError: null, lastIssue: null, refreshFailureCount: 0, nextRetryAt: null } : entry); return { successCount: feed ? 1 : 0, failureCount: 0, skippedCount: 0, statusText: "刷新完成：成功 1、失败 0" }; }
  async refreshAll() { await Promise.all(this.feeds.map((feed) => this.refreshFeed(feed.id))); return { successCount: this.feeds.length, failureCount: 0, skippedCount: 0, statusText: `刷新完成：成功 ${this.feeds.length}、失败 0` }; }
  async listArticles(input: { scope: RssScope; searchText: string; unreadOnly: boolean; author: string | null; tag: string | null; sort: "newest" | "oldest"; offset: number; limit: number }) {
    const matched = filterAndSortArticles(this.headers(), input); const rows = matched.slice(Math.max(0, input.offset), Math.max(0, input.offset) + Math.max(1, input.limit));
    return { articles: rows, totalCount: matched.length, hasMore: input.offset + rows.length < matched.length };
  }
  async getArticle(articleId: string) { return this.articles.find((article) => article.id === articleId) ?? null; }
  async updateArticleState(input: { articleId: string; readAt?: number | null; isStarred?: boolean; tags?: string[] }) {
    const article = this.article(input.articleId); const next = { ...article, ...(Object.prototype.hasOwnProperty.call(input, "readAt") ? { readAt: input.readAt ?? null } : {}), ...(typeof input.isStarred === "boolean" ? { isStarred: input.isStarred } : {}), ...(input.tags ? { tags: normalizedTags(input.tags) } : {}) };
    this.articles = this.articles.map((entry) => entry.id === article.id ? next : entry); return header(next);
  }
  async markAllRead(input: { scope: RssScope; articleIds?: string[]; searchText?: string; unreadOnly?: boolean; author?: string | null; tag?: string | null }) {
    const target = input.articleIds ? new Set(input.articleIds) : new Set(filterAndSortArticles(this.headers(), { scope: input.scope, searchText: input.searchText ?? "", unreadOnly: input.unreadOnly ?? false, author: input.author ?? null, tag: input.tag ?? null, sort: "newest" }).map((article) => article.id)); const now = nowSeconds(); const prior = new Map<string, number | null>();
    this.articles = this.articles.map((article) => { if (target.has(article.id) && !article.readAt) { prior.set(article.id, article.readAt); return { ...article, readAt: now }; } return article; }); const undoToken = prior.size ? `read-${crypto.randomUUID()}` : null; if (undoToken) this.readUndos.set(undoToken, prior); return { changedCount: prior.size, undoToken };
  }
  async undoMarkAllRead(undoToken: string) { const prior = this.readUndos.get(undoToken); if (!prior) return; this.articles = this.articles.map((article) => prior.has(article.id) ? { ...article, readAt: prior.get(article.id) ?? null } : article); this.readUndos.delete(undoToken); }
  async undoRemoveFeed(undoToken: string) { const snapshot = this.removed.get(undoToken); if (!snapshot) return; this.feeds = [...this.feeds, ...snapshot.feeds]; this.articles = [...this.articles, ...snapshot.articles]; this.removed.delete(undoToken); }
  async fetchFullText(articleId: string, force: boolean) { const article = this.article(articleId); const existing = this.fullTexts.get(articleId); if (existing && !force) return existing; const now = nowSeconds(); const record: RssFullTextRecord = { articleId, status: "ready", contentHtml: `<article><p>这是“${escapeHtml(article.title)}”的演示全文缓存。</p>${article.contentHtml}</article>`, plainText: `${article.title}\n${article.readableSummary}`, sourceUrl: article.link, resolvedUrl: article.link, extractorIdentifier: "browser-demo", extractorVersion: "1", sourceEtag: null, sourceLastModified: null, sourceContentHash: null, confidence: .86, attemptedAt: now, retryAfter: null, failureMessage: null }; this.fullTexts.set(articleId, record); return record; }
  async fetchCover() { return null; }
  async listHighlights(articleId: string) { return [...this.highlights.values()].filter((item) => item.articleId === articleId).sort((a, b) => b.updatedAt - a.updatedAt); }
  async saveHighlight(input: { id?: string | null; articleId: string; text: string; note: string; tags: string[] }) { this.article(input.articleId); const old = input.id ? this.highlights.get(input.id) : undefined; const now = nowSeconds(); const record: RssHighlight = { id: old?.id ?? `highlight-${crypto.randomUUID()}`, articleId: input.articleId, text: input.text.trim(), note: input.note.trim(), tags: normalizedTags(input.tags), createdAt: old?.createdAt ?? now, updatedAt: now }; if (!record.text) throw new Error("请先输入要高亮的文字。"); this.highlights.set(record.id, record); return record; }
  async deleteHighlight(highlightId: string) { this.highlights.delete(highlightId); }
  async getReadingProgress(articleId: string) { return this.progress.get(articleId) ?? null; }
  async saveReadingProgress(input: { articleId: string; progress: number; revision: number }) { this.article(input.articleId); const existing = this.progress.get(input.articleId); if (existing && input.revision < existing.revision) return existing; const value: RssReadingProgress = { articleId: input.articleId, progress: Math.min(1, Math.max(0, input.progress)), revision: Math.max(0, input.revision), updatedAt: nowSeconds() }; this.progress.set(input.articleId, value); return value; }
  async importOpml(opml: string) {
    const privacy = await import("./rssOpmlDemoPrivacy");
    const entries = privacy.parseDemoOpml(opml);
    if (privacy.reviewDemoOpml("import", entries).affectedCount > 0) throw new Error("OPML 含隐私风险，请先完成隐私审查。");
    return this.importOpmlUnchecked(entries);
  }
  async exportOpml() {
    const privacy = await import("./rssOpmlDemoPrivacy");
    const opml = this.exportOpmlUnchecked();
    if (privacy.reviewDemoOpml("export", privacy.parseDemoOpml(opml)).affectedCount > 0) throw new Error("OPML 含隐私风险，请先完成隐私审查。");
    return opml;
  }
  async reviewOpml(input: { direction: "import" | "export"; opml?: string }) {
    const privacy = await import("./rssOpmlDemoPrivacy");
    const opml = input.direction === "import" ? input.opml ?? "" : this.exportOpmlUnchecked();
    const review = privacy.reviewDemoOpml(input.direction, privacy.parseDemoOpml(opml));
    while (this.opmlReviews.size >= 2) {
      const oldest = this.opmlReviews.keys().next().value;
      if (oldest) this.opmlReviews.delete(oldest); else break;
    }
    this.opmlReviews.set(review.fingerprint, { direction: input.direction, opml, review });
    return review;
  }
  async executeOpml(input: { direction: "import" | "export"; opml?: string; fingerprint: string; action: "redact" | "exclude" }) {
    const privacy = await import("./rssOpmlDemoPrivacy");
    const saved = this.opmlReviews.get(input.fingerprint);
    if (!saved) throw new Error("OPML 审查已过期，请重新审查。");
    this.opmlReviews.delete(input.fingerprint);
    if (saved.direction !== input.direction || (input.direction === "import" && saved.opml !== (input.opml ?? ""))) throw new Error("OPML 审查已过期，请重新审查。");
    if (input.direction === "export" && saved.opml !== this.exportOpmlUnchecked()) throw new Error("OPML 审查已过期，请重新审查。");
    if (input.action === "redact" && saved.review.blockedCount > 0) throw new Error("OPML 含无法安全脱敏的用户信息，请改为排除风险订阅。");
    const sanitized = privacy.transformDemoOpml(privacy.parseDemoOpml(saved.opml), input.action);
    if (input.direction === "import") {
      const result = this.importOpmlUnchecked(sanitized.entries);
      return { opml: null, importedCount: result.importedCount, skippedCount: result.skippedCount, exportedCount: 0, excludedCount: sanitized.excludedCount };
    }
    return { opml: sanitized.opml, importedCount: 0, skippedCount: 0, exportedCount: saved.review.totalCount - sanitized.excludedCount, excludedCount: sanitized.excludedCount };
  }
  async historyDiscover(): Promise<RssHistoryJob> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async historyResumeDiscovery(): Promise<RssHistoryJob> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async historyCancelDiscovery(): Promise<void> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async historyStatus(): Promise<RssHistoryJob | null> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async historyList(): Promise<RssHistoryCheckpointSummary[]> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async historyClear(): Promise<void> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async historyPrepareRetry(): Promise<RssHistoryJob> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async historyStep(): Promise<RssHistoryJob> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async historyPause(): Promise<RssHistoryJob> { throw new Error("浏览器演示不支持历史文章补全；请在桌面应用中使用此功能。"); }
  async getPreferences() { return this.preferences; }
  async updatePreferences(preferences: RssPreferences) {
    this.preferences = { ...preferences,
      retentionDays: clampInt(preferences.retentionDays, 1, 3650, 90),
      offlineTranslationRetentionDays: clampInt(preferences.offlineTranslationRetentionDays, 1, 3650, 30),
      offlineTranslationMaxMiB: clampInt(preferences.offlineTranslationMaxMiB, 16, 2048, 100),
      automaticLocalPretranslationOnRefreshEnabled: Boolean(preferences.offlineTranslationCacheEnabled && preferences.automaticLocalPretranslationOnRefreshEnabled),
    };
    const timestamp = nowSeconds();
    for (const [key, value] of this.offlineTranslations) if (value.expiresAt <= timestamp) this.offlineTranslations.delete(key);
    await this.enforceOfflineQuota();
    return this.preferences;
  }
  async prune() { const cutoffDate = nowSeconds() - this.preferences.retentionDays * 86400; const removed = this.articles.filter((article) => Boolean(article.readAt) && !article.isStarred && (article.publishedAt ?? article.fetchedAt) < cutoffDate); this.deleteOfflineTranslationsForArticles(new Set(removed.map((article) => article.id))); this.articles = this.articles.filter((article) => !removed.includes(article)); return { removedArticleCount: removed.length, removedMediaAssetCount: 0, cutoffDate }; }
  async exportBackup() { return JSON.stringify({ schemaVersion: 1, feeds: this.feeds, articles: this.articles, highlights: [...this.highlights.values()] }); }
  async inspectBackup(backupText: string) { const backup = parseBackup(backupText); return inspection(backup.feeds, backup.articles, backup.highlights); }
  async restoreBackup(backupText: string) { const backup = parseBackup(backupText); this.offlineTranslations.clear(); this.feeds = backup.feeds; this.articles = backup.articles; this.highlights = new Map(backup.highlights.map((item) => [item.id, item])); return inspection(this.feeds, this.articles, [...this.highlights.values()]); }
  async getOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest }) { if (!this.preferences.offlineTranslationCacheEnabled) return null; const key = await offlineKey(input.articleId, input.request); const record = this.offlineTranslations.get(key); if (!record || record.expiresAt <= nowSeconds()) { if (record) this.offlineTranslations.delete(key); return null; } return { ...record }; }
  async saveOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest; result: TextTranslationResult }) {
    if (!this.preferences.offlineTranslationCacheEnabled) throw new Error("离线译文库未启用。");
    const byteSize = new TextEncoder().encode(input.result.translatedText).byteLength; const maxBytes = this.preferences.offlineTranslationMaxMiB * 1024 * 1024;
    if (byteSize > maxBytes) throw new Error("译文超过离线译文库配额。");
    const now = nowSeconds(); const record: RssOfflineTranslationRecord = { ...input.result, articleId: input.articleId, createdAt: now, expiresAt: now + this.preferences.offlineTranslationRetentionDays * 86400, byteSize };
    this.offlineTranslations.set(await offlineKey(input.articleId, input.request), record); await this.enforceOfflineQuota(); return { ...record };
  }
  async deleteOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest }) { this.offlineTranslations.delete(await offlineKey(input.articleId, input.request)); }
  async offlineTranslationCacheStatus() { const now = nowSeconds(); let expiredCount = 0; for (const value of this.offlineTranslations.values()) if (value.expiresAt <= now) expiredCount += 1; return { entryCount: this.offlineTranslations.size, totalBytes: [...this.offlineTranslations.values()].reduce((sum, value) => sum + value.byteSize, 0), maxBytes: this.preferences.offlineTranslationMaxMiB * 1024 * 1024, expiredCount }; }
  async pruneOfflineTranslations() { const before = this.totalOfflineBytes(); const now = nowSeconds(); let removedCount = 0; for (const [key, value] of this.offlineTranslations) if (value.expiresAt <= now) { this.offlineTranslations.delete(key); removedCount += 1; } const after = this.totalOfflineBytes(); return { removedCount, freedBytes: before - after, remainingCount: this.offlineTranslations.size, remainingBytes: after }; }
  async clearOfflineTranslations(feedId?: string | null) { const before = this.totalOfflineBytes(); let removedCount = 0; for (const [key, value] of this.offlineTranslations) { if (!feedId || this.articles.some((article) => article.id === value.articleId && article.feedId === feedId)) { this.offlineTranslations.delete(key); removedCount += 1; } } const after = this.totalOfflineBytes(); return { removedCount, freedBytes: before - after, remainingCount: this.offlineTranslations.size, remainingBytes: after }; }
  private totalOfflineBytes() { return [...this.offlineTranslations.values()].reduce((sum, value) => sum + value.byteSize, 0); }
  private importOpmlUnchecked(entries: ReadonlyArray<{ feedUrl: string; siteUrl: string | null; title: string }>) {
    const validated = entries.map((entry) => ({ url: safeHttpUrl(entry.feedUrl).toString(), siteUrl: entry.siteUrl ? safeHttpUrl(entry.siteUrl).toString() : null, title: entry.title.trim() }));
    let importedCount = 0; let skippedCount = 0; let nextFeeds = this.feeds;
    for (const entry of validated) {
      if (nextFeeds.some((feed) => feed.url === entry.url)) { skippedCount += 1; continue; }
      const now = nowSeconds(); const host = new URL(entry.url).hostname;
      const feed: RssFeed = { id: `demo-feed-${crypto.randomUUID()}`, title: entry.title || host, url: entry.url, siteUrl: entry.siteUrl, iconUrl: null, addedAt: now, lastUpdatedAt: null, etag: null, lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: null, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: null };
      nextFeeds = [...nextFeeds, feed]; importedCount += 1;
    }
    this.feeds = nextFeeds;
    return { importedCount, skippedCount };
  }
  private exportOpmlUnchecked() { const outlines = this.feeds.map((feed) => `    <outline text="${xml(feed.title)}" title="${xml(feed.title)}" type="rss" xmlUrl="${xml(feed.url)}"${feed.siteUrl ? ` htmlUrl="${xml(feed.siteUrl)}"` : ""}/>`).join("\n"); return `<?xml version="1.0" encoding="UTF-8"?>\n<opml version="2.0">\n  <head><title>RSS Subscriptions</title></head>\n  <body>\n${outlines}\n  </body>\n</opml>\n`; }
  private async enforceOfflineQuota() { const max = this.preferences.offlineTranslationMaxMiB * 1024 * 1024; for (const [key] of [...this.offlineTranslations].sort((a, b) => a[1].createdAt - b[1].createdAt)) { if (this.totalOfflineBytes() <= max) break; this.offlineTranslations.delete(key); } }
  private deleteOfflineTranslationsForArticles(articleIds: Set<string>) { for (const [key, value] of this.offlineTranslations) if (articleIds.has(value.articleId)) this.offlineTranslations.delete(key); }
  private headers() { return this.articles.map(header); }
  private feed(id: string) { const feed = this.feeds.find((entry) => entry.id === id); if (!feed) throw new Error("找不到订阅。"); return feed; }
  private article(id: string) { const article = this.articles.find((entry) => entry.id === id); if (!article) throw new Error("找不到文章。"); return article; }
}

function isTauriRuntime() { return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window; }
function nowSeconds() { return Math.floor(Date.now() / 1000); }
function clampInt(value: number, min: number, max: number, fallback: number) { return Math.max(min, Math.min(max, Math.round(Number.isFinite(value) ? value : fallback))); }
async function offlineKey(articleId: string, request: PlanTextTranslationRequest) {
  const canonical = JSON.stringify({ articleId, provider: request.provider, endpoint: request.endpoint.trim(), model: request.model.trim(), sourceLanguage: request.sourceLanguage.trim(), targetLanguage: request.targetLanguage.trim(), text: request.text, glossary: request.glossary ?? [] });
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) throw new Error("当前浏览器不支持安全的离线译文索引。");
  const digest = await subtle.digest("SHA-256", new TextEncoder().encode(canonical));
  return `sha256:${[...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}
function safeHttpUrl(value: string) { const url = new URL(value.trim()); if (!/^https?:$/.test(url.protocol) || !url.hostname || url.username || url.password) throw new Error("订阅地址必须是无凭据的 http 或 https URL。"); return url; }
function normalizedTags(tags: string[]) { return [...new Map(tags.map((tag) => tag.trim().slice(0, 80)).filter(Boolean).map((tag) => [tag.toLocaleLowerCase(), tag])).values()]; }
function countSnapshotArticles(articles: RssArticleHeader[]) {
  const unreadCountByFeed: Record<string, number> = {};
  let unreadCount = 0; let starredCount = 0;
  for (const article of articles) {
    if (!article.readAt) { unreadCount += 1; unreadCountByFeed[article.feedId] = (unreadCountByFeed[article.feedId] ?? 0) + 1; }
    if (article.isStarred) starredCount += 1;
  }
  return { articleCount: articles.length, unreadCount, starredCount, unreadCountByFeed };
}
function header(article: RssArticle): RssArticleHeader { const { summaryHtml: _, contentHtml: __, webPageSnapshotHtml: ___, ...value } = article; return value; }
function xml(value: string) { return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;"); }
function escapeHtml(value: string) { return xml(value).replace(/>/g, "&gt;"); }
function parseBackup(value: string): { feeds: RssFeed[]; articles: RssArticle[]; highlights: RssHighlight[] } { try { const parsed = JSON.parse(value) as { feeds?: unknown; articles?: unknown; highlights?: unknown }; if (!Array.isArray(parsed.feeds) || !Array.isArray(parsed.articles) || !Array.isArray(parsed.highlights)) throw new Error("格式不完整"); return parsed as { feeds: RssFeed[]; articles: RssArticle[]; highlights: RssHighlight[] }; } catch { throw new Error("RSS 备份文本无法验证。仅可导入由 RepoPress 导出的备份。"); } }
function inspection(feeds: RssFeed[], articles: RssArticle[], highlights: RssHighlight[]): RssBackupInspection { return { databaseSchemaVersion: 1, feedCount: feeds.length, articleCount: articles.length, highlightCount: highlights.length, indexedArticleCount: articles.length }; }
function seedFeeds(): RssFeed[] { const now = nowSeconds(); return [{ id: "demo-feed-design", title: "设计与工程", url: "https://example.com/design/feed.xml", siteUrl: "https://example.com/design", iconUrl: null, addedAt: now - 1209600, lastUpdatedAt: now - 1800, etag: "demo", lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: now - 1800, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: 0.14 }, { id: "demo-feed-open", title: "开源周刊", url: "https://example.org/feed.xml", siteUrl: "https://example.org", iconUrl: null, addedAt: now - 604800, lastUpdatedAt: now - 3600, etag: null, lastModified: null, lastError: null, lastIssue: null, lastRefreshAttemptAt: now - 3600, refreshFailureCount: 0, nextRetryAt: null, lastRefreshDuration: 0.09 }]; }
function seedArticles(): RssArticle[] { const now = nowSeconds(); return [{ id: "demo-article-1", feedId: "demo-feed-design", title: "把阅读列表变成安静的工作台", link: "https://example.com/design/reading", coverUrl: null, author: "RepoPress", publishedAt: now - 7200, fetchedAt: now - 7000, readAt: null, isStarred: true, tags: ["设计", "阅读"], readableSummary: "用更少的打扰，把发现、筛选和深入阅读收拢到一个稳定的节奏里。", summaryHtml: "<p>用更少的打扰，把发现、筛选和深入阅读收拢到一个稳定的节奏里。</p>", contentHtml: "<article><p>阅读器最重要的事情，是让人能够专注于文章，而不是界面。</p><h2>稳定的节奏</h2><p>订阅、筛选和稍后阅读应当保留在本机，并能随时恢复。</p></article>", webPageSnapshotHtml: null }, { id: "demo-article-2", feedId: "demo-feed-open", title: "本周值得关注的开源项目", link: "https://example.org/week", coverUrl: null, author: "开源周刊", publishedAt: now - 86400, fetchedAt: now - 85000, readAt: null, isStarred: false, tags: ["开源"], readableSummary: "从小型命令行工具到注重隐私的桌面应用。", summaryHtml: "<p>从小型命令行工具到注重隐私的桌面应用。</p>", contentHtml: "<article><p>本周收录几个小而完整的开源项目。</p><ul><li>可靠的本地索引</li><li>清晰的错误恢复</li></ul></article>", webPageSnapshotHtml: null }, { id: "demo-article-3", feedId: "demo-feed-design", title: "用可见的状态替代不确定的等待", link: "https://example.com/design/status", coverUrl: null, author: "RepoPress", publishedAt: now - 172800, fetchedAt: now - 172700, readAt: now - 160000, isStarred: false, tags: ["体验", "设计"], readableSummary: "加载、错误和刷新状态都应该让人一眼看懂。", summaryHtml: "<p>加载、错误和刷新状态都应该让人一眼看懂。</p>", contentHtml: "<article><p>明确告诉用户发生了什么，是可靠体验的一部分。</p></article>", webPageSnapshotHtml: null }]; }
