import { describe, expect, it } from "vitest";
import { createRssGateway } from "./rssGateway";

describe("browser RSS gateway", () => {
  it("keeps full text, highlights, progress and undo state in memory", async () => {
    const gateway = createRssGateway(); const snapshot = await gateway.snapshot(); const article = snapshot.articles[0];
    expect(snapshot.articleCount).toBe(snapshot.articles.length); expect(snapshot.unreadCount).toBeGreaterThan(0); expect(snapshot.unreadCountByFeed[article.feedId]).toBeGreaterThan(0); expect(snapshot.authors).toContain("RepoPress"); expect(snapshot.tags).toContain("设计");
    const fullText = await gateway.fetchFullText(article.id, false); expect(fullText.status).toBe("ready");
    const highlight = await gateway.saveHighlight({ articleId: article.id, text: "可引用的句子", note: "笔记", tags: ["研究"] }); expect((await gateway.listHighlights(article.id))[0].id).toBe(highlight.id);
    expect((await gateway.saveReadingProgress({ articleId: article.id, progress: .6, revision: 1 })).progress).toBe(.6);
    await gateway.saveReadingProgress({ articleId: article.id, progress: .8, revision: 3 });
    expect((await gateway.saveReadingProgress({ articleId: article.id, progress: .2, revision: 2 })).progress).toBe(.8);
    const marked = await gateway.markAllRead({ scope: "all", articleIds: [article.id] }); expect(typeof marked === "number" ? marked : marked.changedCount).toBeGreaterThanOrEqual(1); if (typeof marked !== "number" && marked.undoToken) await gateway.undoMarkAllRead(marked.undoToken);
  });
  it("exports, inspects and restores text backups plus deleted feeds", async () => {
    const gateway = createRssGateway(); const initial = await gateway.snapshot(); const backup = await gateway.exportBackup(); expect((await gateway.inspectBackup(backup)).articleCount).toBe(initial.articles.length);
    const removed = await gateway.removeFeed(initial.feeds[0].id); if (removed?.undoToken) await gateway.undoRemoveFeed(removed.undoToken); expect((await gateway.snapshot()).feeds).toHaveLength(initial.feeds.length);
    await gateway.restoreBackup(backup); expect((await gateway.snapshot()).articles).toHaveLength(initial.articles.length);
  });
});

describe("Tauri RSS gateway contract", () => {
  it("passes the refresh force policy explicitly", async () => {
    const calls: Array<{ name: string; args?: object }> = [];
    const invoke = async <T>(name: string, args?: object): Promise<T> => { calls.push({ name, args }); return { successCount: 0, failureCount: 0, skippedCount: 0 } as T; };
    const gateway = createRssGateway(invoke);
    await gateway.refreshAll(false);
    await gateway.refreshFeed("feed", true);
    await gateway.refreshAll();
    expect(calls).toEqual([
      { name: "rss_refresh_all", args: { force: false } },
      { name: "rss_refresh_feed", args: { feedId: "feed", force: true } },
      { name: "rss_refresh_all", args: { force: false } },
    ]);
  });

  it("uses the exact desktop command names and camelCase arguments", async () => {
    const calls: Array<{ name: string; args?: object }> = [];
    const invoke = async <T>(name: string, args?: object): Promise<T> => {
      calls.push({ name, args });
      if (name === "rss_save_reading_progress") return { articleId: "article", progress: .5, revision: 7, updatedAt: 1 } as T;
      if (name === "rss_inspect_backup" || name === "rss_restore_backup") return { databaseSchemaVersion: 2, feedCount: 0, articleCount: 0, highlightCount: 0, indexedArticleCount: 0 } as T;
      return undefined as T;
    };
    const gateway = createRssGateway(invoke);
    await gateway.saveReadingProgress({ articleId: "article", progress: .5, revision: 7 });
    await gateway.markAllRead({ scope: "unread", searchText: "needle", unreadOnly: true, author: "Ada", tag: "rss" });
    await gateway.fetchCover("article");
    await gateway.deleteHighlight("highlight");
    await gateway.inspectBackup("backup");
    await gateway.restoreBackup("backup");
    await gateway.undoRemoveFeed("remove-token");
    await gateway.undoMarkAllRead("read-token");
    await gateway.reviewOpml({ direction: "import", opml: "<opml/>" });
    await gateway.executeOpml({ direction: "export", fingerprint: "digest", action: "exclude" });
    await gateway.historyDiscover({ feedId: "feed", directoryUrl: "https://example.com/archive/", maxPages: 10, maxArticles: 100, discoveryId: "00000000-0000-4000-8000-000000000001", fillExisting: true });
    await gateway.historyResumeDiscovery({ jobId: "job", discoveryId: "00000000-0000-4000-8000-000000000002", maxPages: 10, maxArticles: 100 });
    await gateway.historyCancelDiscovery("00000000-0000-4000-8000-000000000001");
    await gateway.historyStatus("feed");
    await gateway.historyList();
    await gateway.historyClear("job");
    await gateway.historyPrepareRetry({ jobId: "job", maxArticles: 500 });
    await gateway.historyStep({ jobId: "job", retryFailures: true });
    await gateway.historyPause("job");
    expect(calls).toEqual([
      { name: "rss_save_reading_progress", args: { articleId: "article", progress: .5, revision: 7 } },
      { name: "rss_mark_all_read", args: { scope: "unread", searchText: "needle", unreadOnly: true, author: "Ada", tag: "rss" } },
      { name: "rss_fetch_cover", args: { articleId: "article" } },
      { name: "rss_delete_highlight", args: { highlightId: "highlight" } },
      { name: "rss_inspect_backup", args: { backupText: "backup" } },
      { name: "rss_restore_backup", args: { backupText: "backup" } },
      { name: "rss_undo_remove_feed", args: { undoToken: "remove-token" } },
      { name: "rss_undo_mark_all_read", args: { undoToken: "read-token" } },
      { name: "rss_review_opml", args: { input: { direction: "import", opml: "<opml/>" } } },
      { name: "rss_execute_opml", args: { input: { direction: "export", fingerprint: "digest", action: "exclude" } } },
      { name: "rss_history_discover", args: { input: { feedId: "feed", directoryUrl: "https://example.com/archive/", maxPages: 10, maxArticles: 100, discoveryId: "00000000-0000-4000-8000-000000000001", fillExisting: true } } },
      { name: "rss_history_resume_discovery", args: { input: { jobId: "job", discoveryId: "00000000-0000-4000-8000-000000000002", maxPages: 10, maxArticles: 100 } } },
      { name: "rss_history_cancel_discovery", args: { discoveryId: "00000000-0000-4000-8000-000000000001" } },
      { name: "rss_history_status", args: { feedId: "feed" } },
      { name: "rss_history_list", args: undefined },
      { name: "rss_history_clear", args: { jobId: "job" } },
      { name: "rss_history_prepare_retry", args: { input: { jobId: "job", maxArticles: 500 } } },
      { name: "rss_history_step", args: { input: { jobId: "job", retryFailures: true } } },
      { name: "rss_history_pause", args: { jobId: "job" } },
    ]);
  });

  it("uses nested offline translation requests and cleanup arguments", async () => {
    const calls: Array<{ name: string; args?: object }> = [];
    const invoke = async <T>(name: string, args?: object): Promise<T> => { calls.push({ name, args }); return undefined as T; };
    const gateway = createRssGateway(invoke);
    const request = { provider: "libretranslate_local" as const, endpoint: "http://127.0.0.1:5000", model: "", sourceLanguage: "en", targetLanguage: "zh", text: "Hello" };
    const result = { translatedText: "你好", detectedSourceLanguage: "en", provider: request.provider, model: "", targetLanguage: "zh" };
    await gateway.getOfflineTranslation({ articleId: "article", request });
    await gateway.saveOfflineTranslation({ articleId: "article", request, result });
    await gateway.deleteOfflineTranslation({ articleId: "article", request });
    await gateway.offlineTranslationCacheStatus();
    await gateway.pruneOfflineTranslations();
    await gateway.clearOfflineTranslations();
    expect(calls).toEqual([
      { name: "rss_get_offline_translation", args: { request: { articleId: "article", ...request } } },
      { name: "rss_save_offline_translation", args: { request: { articleId: "article", ...request }, result } },
      { name: "rss_delete_offline_translation", args: { request: { articleId: "article", ...request } } },
      { name: "rss_offline_translation_cache_status" },
      { name: "rss_prune_offline_translations" },
      { name: "rss_clear_offline_translations", args: { feedId: null } },
    ]);
  });
});

describe("browser OPML privacy flow", () => {
  it("binds execution to review and never preserves reviewed risks", async () => {
    const gateway = createRssGateway();
    const source = '<opml version="2.0"><body><outline text="A" xmlUrl="https://example.net/feed?token=secret"/><outline text="B" xmlUrl="https://user:secret@example.net/private"/></body></opml>';
    await expect(gateway.importOpml(source)).rejects.toThrow("隐私审查");
    const review = await gateway.reviewOpml({ direction: "import", opml: source });
    expect(review).toMatchObject({ totalCount: 2, affectedCount: 2, blockedCount: 1 });
    expect(JSON.stringify(review)).not.toContain("secret");
    await expect(gateway.executeOpml({ direction: "import", opml: source, fingerprint: review.fingerprint, action: "redact" })).rejects.toThrow("排除");
    const second = await gateway.reviewOpml({ direction: "import", opml: source });
    const result = await gateway.executeOpml({ direction: "import", opml: source, fingerprint: second.fingerprint, action: "exclude" });
    expect(result).toMatchObject({ importedCount: 0, excludedCount: 2, opml: null });
  });

  it("parses decoded OPML metadata and validates the whole document before mutation", async () => {
    const gateway = createRssGateway(); const before = (await gateway.snapshot()).feeds.length;
    const safe = '<opml version="2.0"><head><title>Safe</title></head><body><outline text="A &amp; B" xmlUrl="https://demo.example/feed?a=1&amp;b=2" htmlUrl="https://demo.example/site?a=1&amp;b=2"/></body></opml>';
    expect(await gateway.importOpml(safe)).toEqual({ importedCount: 1, skippedCount: 0 });
    const imported = (await gateway.snapshot()).feeds.find((feed) => feed.url.startsWith("https://demo.example/feed"));
    expect(imported).toMatchObject({ title: "A & B", siteUrl: "https://demo.example/site?a=1&b=2" }); expect(imported?.url).toBe("https://demo.example/feed?a=1&b=2");
    const invalid = '<opml version="2.0"><body><outline text="Would mutate" xmlUrl="https://new.example/feed"/><outline text="Invalid" xmlUrl="ftp://new.example/feed"/></body></opml>';
    await expect(gateway.importOpml(invalid)).rejects.toThrow("隐私审查"); expect((await gateway.snapshot()).feeds).toHaveLength(before + 1);
  });

  it("rejects oversized, deeply nested, excessive, and DTD-bearing OPML", async () => {
    const gateway = createRssGateway();
    const deep = `<opml version="2.0"><body>${"<outline>".repeat(257)}${"</outline>".repeat(257)}</body></opml>`;
    const excessive = `<opml version="2.0"><body>${'<outline xmlUrl="https://example.com/feed"/>'.repeat(10_001)}</body></opml>`;
    const oversized = `<opml version="2.0"><body><!--${"x".repeat(4 * 1024 * 1024)}--></body></opml>`;
    const dtd = '<!DOCTYPE opml [<!ENTITY secret "value">]><opml version="2.0"><body/></opml>';
    for (const opml of [deep, excessive, oversized, dtd]) await expect(gateway.reviewOpml({ direction: "import", opml })).rejects.toThrow(/OPML/);
  });

  it("keeps only two opaque reviews and consumes a review on a mismatched attempt", async () => {
    const gateway = createRssGateway();
    const source = '<opml version="2.0"><body><outline text="A" xmlUrl="https://example.net/feed?token=secret"/></body></opml>';
    const first = await gateway.reviewOpml({ direction: "import", opml: source }); const second = await gateway.reviewOpml({ direction: "import", opml: source }); const third = await gateway.reviewOpml({ direction: "import", opml: source });
    expect(new Set([first.fingerprint, second.fingerprint, third.fingerprint]).size).toBe(3);
    await expect(gateway.executeOpml({ direction: "import", opml: source, fingerprint: first.fingerprint, action: "exclude" })).rejects.toThrow("过期");
    await expect(gateway.executeOpml({ direction: "import", opml: `${source} `, fingerprint: second.fingerprint, action: "exclude" })).rejects.toThrow("过期");
    await expect(gateway.executeOpml({ direction: "import", opml: source, fingerprint: second.fingerprint, action: "exclude" })).rejects.toThrow("过期");
  });

  it("reviews title URL secrets without leaking them and redacts or excludes imports", async () => {
    const source = '<opml version="2.0"><body><outline text="Read https://alice:title-secret@example.com/private" xmlUrl="https://feed-one.example/rss" custom="discard"><outline title="Token https://example.com/post?api_token=query-secret" xmlUrl="https://feed-two.example/rss"/></outline></body></opml>';
    const gateway = createRssGateway();
    await expect(gateway.importOpml(source)).rejects.toThrow("隐私审查");
    const review = await gateway.reviewOpml({ direction: "import", opml: source });
    expect(review).toMatchObject({ totalCount: 2, affectedCount: 2, blockedCount: 0 });
    expect(review.findings.every((finding) => finding.location === "title")).toBe(true);
    const renderedReview = JSON.stringify(review);
    for (const secret of ["alice", "title-secret", "query-secret"]) expect(renderedReview).not.toContain(secret);
    const redacted = await gateway.executeOpml({ direction: "import", opml: source, fingerprint: review.fingerprint, action: "redact" });
    expect(redacted).toMatchObject({ importedCount: 2, excludedCount: 0 });
    const titles = (await gateway.snapshot()).feeds.filter((feed) => feed.url.includes("feed-one.example") || feed.url.includes("feed-two.example")).map((feed) => feed.title);
    expect(titles).toEqual(["feed-one.example", "feed-two.example"]);

    const excludingGateway = createRssGateway();
    const excludingReview = await excludingGateway.reviewOpml({ direction: "import", opml: source });
    const excluded = await excludingGateway.executeOpml({ direction: "import", opml: source, fingerprint: excludingReview.fingerprint, action: "exclude" });
    expect(excluded).toMatchObject({ importedCount: 0, excludedCount: 2 });
  });

  it("sanitizes risky export titles and omits excluded entries", async () => {
    const gateway = createRssGateway();
    await gateway.addFeed({ url: "https://title-export.example/feed", title: "Read https://bob:export-secret@private.example/post?auth_token=query-secret" });
    await expect(gateway.exportOpml()).rejects.toThrow("隐私审查");
    const review = await gateway.reviewOpml({ direction: "export" });
    expect(review).toMatchObject({ affectedCount: 1, blockedCount: 0 });
    const renderedReview = JSON.stringify(review);
    for (const secret of ["bob", "export-secret", "query-secret"]) expect(renderedReview).not.toContain(secret);
    const redacted = await gateway.executeOpml({ direction: "export", fingerprint: review.fingerprint, action: "redact" });
    expect(redacted.opml).toContain('text="title-export.example"');
    expect(redacted.opml).not.toContain("private.example");
    expect(redacted.opml).not.toContain("export-secret");

    const excludingReview = await gateway.reviewOpml({ direction: "export" });
    const excluded = await gateway.executeOpml({ direction: "export", fingerprint: excludingReview.fingerprint, action: "exclude" });
    expect(excluded).toMatchObject({ excludedCount: 1, exportedCount: 2 });
    expect(excluded.opml).not.toContain("title-export.example/feed");
  });

  it("fails closed for oversized or unparsable title URLs", async () => {
    const gateway = createRssGateway();
    const longSecret = `https://example.com/?token=${"s".repeat(4_100)}`;
    const longSource = `<opml version="2.0"><body><outline text="${longSecret}" xmlUrl="https://feed.example/rss"/></body></opml>`;
    const longReview = await gateway.reviewOpml({ direction: "import", opml: longSource });
    expect(longReview).toMatchObject({ affectedCount: 1, blockedCount: 1 });
    expect(JSON.stringify(longReview)).not.toContain(longSecret);
    await expect(gateway.executeOpml({ direction: "import", opml: longSource, fingerprint: longReview.fingerprint, action: "redact" })).rejects.toThrow("排除");

    const malformed = '<opml version="2.0"><body><outline text="Broken https://" xmlUrl="https://feed.example/rss"/></body></opml>';
    const malformedReview = await gateway.reviewOpml({ direction: "import", opml: malformed });
    expect(malformedReview).toMatchObject({ affectedCount: 1, blockedCount: 1 });
    expect(malformedReview.findings[0]).toMatchObject({ location: "title", displayUrl: "Title URL (cannot be safely displayed)" });
  });

  it("reports history backfill as unavailable instead of simulating it", async () => {
    const gateway = createRssGateway();
    await expect(gateway.historyStatus("feed")).rejects.toThrow("桌面应用");
    await expect(gateway.historyDiscover({ feedId: "feed", directoryUrl: "https://example.com/", maxPages: 1, maxArticles: 1, discoveryId: "00000000-0000-4000-8000-000000000001" })).rejects.toThrow("桌面应用");
    await expect(gateway.historyResumeDiscovery({ jobId: "job", discoveryId: "00000000-0000-4000-8000-000000000002", maxPages: 1, maxArticles: 1 })).rejects.toThrow("桌面应用");
    await expect(gateway.historyCancelDiscovery("00000000-0000-4000-8000-000000000001")).rejects.toThrow("桌面应用");
    await expect(gateway.historyList()).rejects.toThrow("桌面应用");
    await expect(gateway.historyClear("job")).rejects.toThrow("桌面应用");
  });
});

describe("browser offline translation cache", () => {
  const request = { provider: "libretranslate_local" as const, endpoint: "http://127.0.0.1:5000", model: "", sourceLanguage: "en", targetLanguage: "zh", text: "Hello" };
  const result = { translatedText: "你好", detectedSourceLanguage: "en", provider: request.provider, model: "", targetLanguage: "zh" };

  it("is default-off and does not expose source text in records", async () => {
    const gateway = createRssGateway(); const articleId = (await gateway.snapshot()).articles[0].id;
    expect(await gateway.getOfflineTranslation({ articleId, request })).toBeNull();
    await expect(gateway.saveOfflineTranslation({ articleId, request, result })).rejects.toThrow("未启用");
    expect(await gateway.offlineTranslationCacheStatus()).toMatchObject({ entryCount: 0, totalBytes: 0 });
  });

  it("supports enable, lookup, delete and clear", async () => {
    const gateway = createRssGateway(); const articleId = (await gateway.snapshot()).articles[0].id;
    await gateway.updatePreferences({ ...(await gateway.getPreferences()), offlineTranslationCacheEnabled: true, automaticLocalPretranslationOnRefreshEnabled: true, offlineTranslationRetentionDays: 30, offlineTranslationMaxMiB: 16 });
    const saved = await gateway.saveOfflineTranslation({ articleId, request, result });
    expect(saved).toMatchObject({ articleId, translatedText: "你好" }); expect(saved).not.toHaveProperty("text");
    expect((await gateway.getOfflineTranslation({ articleId, request }))?.translatedText).toBe("你好");
    expect((await gateway.offlineTranslationCacheStatus()).entryCount).toBe(1);
    await gateway.deleteOfflineTranslation({ articleId, request }); expect((await gateway.offlineTranslationCacheStatus()).entryCount).toBe(0);
  });

  it("drops derived translations when source articles are removed or a backup is restored", async () => {
    const gateway = createRssGateway(); const snapshot = await gateway.snapshot(); const article = snapshot.articles[0]; const backup = await gateway.exportBackup();
    await gateway.updatePreferences({ ...(await gateway.getPreferences()), offlineTranslationCacheEnabled: true, automaticLocalPretranslationOnRefreshEnabled: false, offlineTranslationRetentionDays: 30, offlineTranslationMaxMiB: 16 });
    await gateway.saveOfflineTranslation({ articleId: article.id, request, result });
    await gateway.removeFeed(article.feedId);
    expect((await gateway.offlineTranslationCacheStatus()).entryCount).toBe(0);
    await gateway.restoreBackup(backup);
    await gateway.saveOfflineTranslation({ articleId: article.id, request, result });
    await gateway.restoreBackup(backup);
    expect((await gateway.offlineTranslationCacheStatus()).entryCount).toBe(0);
  });
});
