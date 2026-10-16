import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { RepositoryGateway, TextTranslationResult } from "../contracts/repository";
import type { RssArticle, RssArticleHeader, RssFeed, RssFullTextRecord, RssGateway, RssHighlight, RssOfflineTranslationCacheStatus, RssPreferences, RssScope, RssSortOrder } from "../features/rss/contracts";
import { RSS_PAGE_SIZE, RSS_READING_STYLE_STORAGE_KEY, defaultReadingStyle, didReachReadingCompletion, feedHealth, filterAndSortArticles, normalizeReadingStyle, rssArticlePlainText, safeExternalHttpUrl, sanitizeArticleHtml, shouldPersistReadingProgress, type RssReadingStyle } from "../features/rss/rssReader";
import { RssTranslationPanel, type RssTranslationResultChange } from "../features/translation/RssTranslationPanel";
import { RssBatchTranslationDialog } from "../features/translation/RssBatchTranslationDialog";
import { buildStructuredTranslation, structuredTranslationText } from "../features/translation/structuredTranslation";
import { buildStructuredHtmlTranslationPlan, decodeStructuredTextTranslationResult, reconstructStructuredHtmlTranslation } from "../features/translation/structuredHtmlTranslation";
import { TranslationSessionCache } from "../features/translation/translationSessionCache";
import { useI18n, type UiTranslator } from "../i18n/i18n";
import { rssMessages } from "../i18n/rssMessages";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import { RssHistoryBackfillDialog } from "./RssHistoryBackfillDialog";
import { RssHistoryQueueDialog } from "./RssHistoryQueueDialog";
import { RssOpmlPrivacyDialog } from "./RssOpmlPrivacyDialog";
import { isRssRefreshBusy, runRssRefreshExclusive, subscribeRssRefresh } from "../features/rss/rssRefreshController";
import "../features/rss/RssReader.css";

type AddMode = "add" | "opml" | "preferences" | "backup" | "translation" | "history" | null;
type ArticleTranslationView = "original" | "translation" | "comparison";
type ReaderMessage = { kind: "raw"; text: string } | { kind: "local"; message: UiMessage };
const initialPreferences: RssPreferences = { automaticPruningEnabled: false, retentionDays: 90, feedBodyOfflineCacheEnabled: false, privateNetworkAccessEnabled: false, backgroundRefreshEnabled: true, backgroundRefreshIntervalMinutes: 30, automaticMarkReadAtEndEnabled: true, automaticFullTextExtractionEnabled: false, offlineCacheFullTextOnRefreshEnabled: false, remoteImagesEnabled: false, offlineTranslationCacheEnabled: false, offlineTranslationRetentionDays: 30, offlineTranslationMaxMiB: 100, automaticLocalPretranslationOnRefreshEnabled: false };
const RSS_COVER_CACHE_LIMIT = 24;

export interface RssReaderActions {
  onSaveToKnowledge?: (input: RssArticleWorkflowInput) => Promise<void>;
  onInsertReference?: (input: RssArticleWorkflowInput) => Promise<void>;
  onCreateInspirationDraft?: (input: RssArticleWorkflowInput) => Promise<void> | void;
}

export interface RssReaderProps extends RssReaderActions {
  gateway: RssGateway;
  active: boolean;
  translationGateway?: Pick<RepositoryGateway, "planTextTranslation" | "executeTextTranslation" | "planStructuredTextTranslation" | "executeStructuredTextTranslation" | "aiCredentialStatus" | "storeAiCredential" | "deleteAiCredential">;
}

export type RssArticleWorkflowInput = { article: RssArticle; feed: RssFeed | null; text: string };

export function RssReader({ gateway, active, translationGateway, onSaveToKnowledge, onInsertReference, onCreateInspirationDraft }: RssReaderProps) {
  const { locale, t } = useI18n(rssMessages);
  const [feeds, setFeeds] = useState<RssFeed[]>([]);
  const [libraryCounts, setLibraryCounts] = useState({ articleCount: 0, unreadCount: 0, starredCount: 0, unreadCountByFeed: {} as Record<string, number> });
  const [availableAuthors, setAvailableAuthors] = useState<string[]>([]);
  const [availableTags, setAvailableTags] = useState<string[]>([]);
  const [articles, setArticles] = useState<RssArticleHeader[]>([]);
  const [totalCount, setTotalCount] = useState(0);
  const [hasMore, setHasMore] = useState(false);
  const [scope, setScope] = useState<RssScope>("all");
  const [searchText, setSearchText] = useState("");
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [author, setAuthor] = useState<string | null>(null);
  const [tag, setTag] = useState<string | null>(null);
  const [sort, setSort] = useState<RssSortOrder>("newest");
  const [selectedArticleId, setSelectedArticleId] = useState<string | null>(null);
  const [selectedArticle, setSelectedArticle] = useState<RssArticle | null>(null);
  const [loading, setLoading] = useState(false);
  const [articleLoading, setArticleLoading] = useState(false);
  const [status, setStatus] = useState<ReaderMessage | null>(null);
  const [error, setError] = useState<ReaderMessage | null>(null);
  const [dialog, setDialog] = useState<AddMode>(null);
  const [address, setAddress] = useState("");
  const [discovered, setDiscovered] = useState<string[]>([]);
  const [selectedDiscovery, setSelectedDiscovery] = useState<Set<string>>(new Set());
  const [historyFeedId, setHistoryFeedId] = useState<string | null>(null);
  const [preferences, setPreferences] = useState<RssPreferences>(initialPreferences);
  const [preferencesLoaded, setPreferencesLoaded] = useState(false);
  const [fullText, setFullText] = useState<RssFullTextRecord | null>(null);
  const [showFullText, setShowFullText] = useState(false);
  const [fullTextBusy, setFullTextBusy] = useState(false);
  const [coverDataUrl, setCoverDataUrl] = useState<string | null>(null);
  const [coverBusy, setCoverBusy] = useState(false);
  const [coverError, setCoverError] = useState<ReaderMessage | null>(null);
  const [highlights, setHighlights] = useState<RssHighlight[]>([]);
  const [progress, setProgress] = useState(0);
  const [selectedArticleIds, setSelectedArticleIds] = useState<Set<string>>(new Set());
  const [batchSaving, setBatchSaving] = useState(false);
  const [undo, setUndo] = useState<{ token: string; message: ReaderMessage; kind: "feed" | "read" } | null>(null);
  const [backupText, setBackupText] = useState("");
  const [backupInfo, setBackupInfo] = useState<ReaderMessage | null>(null);
  const [cacheRevision, setCacheRevision] = useState(0);
  const [offlineTranslationStatus, setOfflineTranslationStatus] = useState<RssOfflineTranslationCacheStatus | null>(null);
  const [refreshEnqueue, setRefreshEnqueue] = useState<{ id: number; feedId?: string } | undefined>();
  const [readingStyle, setReadingStyle] = useState<RssReadingStyle>(() => { try { return normalizeReadingStyle(JSON.parse(localStorage.getItem(RSS_READING_STYLE_STORAGE_KEY) ?? "{}")); } catch { return defaultReadingStyle; } });
  const request = useRef(0);
  const articleRequest = useRef(0);
  const fullTextRequest = useRef(0);
  const coverRequest = useRef(0);
  const coverCache = useRef(new Map<string, string>());
  const translationSessionCache = useRef(new TranslationSessionCache(128));
  const progressState = useRef<{ articleId: string | null; progress: number; revision: number }>({ articleId: null, progress: 0, revision: 0 });
  const mountedRef = useRef(false);
  const lifecycleGenerationRef = useRef(0);
  const previousLifecycleRef = useRef({ gateway, active });
  if (previousLifecycleRef.current.gateway !== gateway || previousLifecycleRef.current.active !== active) {
    lifecycleGenerationRef.current += 1;
    previousLifecycleRef.current = { gateway, active };
  }
  const lifecycleRef = useRef({ gateway, active });
  lifecycleRef.current = { gateway, active };
  const isCurrent = useCallback((generation = lifecycleGenerationRef.current) => mountedRef.current && generation === lifecycleGenerationRef.current && lifecycleRef.current.gateway === gateway && lifecycleRef.current.active, [gateway]);
  const refreshing = useSyncExternalStore(useCallback((listener) => subscribeRssRefresh(gateway, listener), [gateway]), useCallback(() => isRssRefreshBusy(gateway), [gateway]), useCallback(() => false, []));
  const onTranslationCacheChange = useCallback(() => setCacheRevision((revision) => revision + 1), []);
  const loadOfflineTranslationStatus = useCallback(async () => { try { setOfflineTranslationStatus(await gateway.offlineTranslationCacheStatus()); } catch { setOfflineTranslationStatus(null); } }, [gateway]);

  const visibleArticles = useMemo(() => filterAndSortArticles(articles, { scope: "all", searchText: "", unreadOnly: false, author, tag, sort }), [articles, author, tag, sort]);

  const loadSnapshot = useCallback(async () => {
    const generation = lifecycleGenerationRef.current;
    const [snapshot, nextPreferences] = await Promise.all([gateway.snapshot(), gateway.getPreferences()]);
    if (!isCurrent(generation)) return;
    setFeeds(snapshot.feeds); setPreferences(nextPreferences);
    setPreferencesLoaded(true);
    setLibraryCounts({ articleCount: snapshot.articleCount, unreadCount: snapshot.unreadCount, starredCount: snapshot.starredCount, unreadCountByFeed: snapshot.unreadCountByFeed });
    setAvailableAuthors(snapshot.authors); setAvailableTags(snapshot.tags);
    if (snapshot.statusMessage) setStatus(rawMessage(snapshot.statusMessage));
    if (snapshot.errorMessage) setError(rawMessage(snapshot.errorMessage));
  }, [gateway, isCurrent]);

  const loadArticles = useCallback(async (offset = 0, append = false) => {
    const generation = lifecycleGenerationRef.current;
    const sequence = ++request.current;
    setLoading(true); setError(null);
    try {
      const page = await gateway.listArticles({ scope, searchText, unreadOnly, author, tag, sort, offset, limit: RSS_PAGE_SIZE });
      if (sequence !== request.current || !isCurrent(generation)) return;
      setArticles((current) => append ? [...current, ...page.articles.filter((article) => !current.some((old) => old.id === article.id))] : page.articles);
      setTotalCount(page.totalCount); setHasMore(page.hasMore);
    } catch (caught) { if (sequence === request.current && isCurrent(generation)) setError(messageFrom(caught)); }
    finally { if (sequence === request.current && isCurrent(generation)) setLoading(false); }
  }, [gateway, scope, searchText, unreadOnly, author, tag, sort, isCurrent]);

  const refreshViewRef = useRef({ loadSnapshot, loadArticles, preferences });
  refreshViewRef.current = { loadSnapshot, loadArticles, preferences };

  useEffect(() => {
    mountedRef.current = true;
    setPreferencesLoaded(false);
    const generation = lifecycleGenerationRef.current;
    if (active) void loadSnapshot().catch((caught) => { if (isCurrent(generation)) setError(messageFrom(caught)); });
    return () => { mountedRef.current = false; lifecycleGenerationRef.current += 1; };
  }, [active, gateway, loadSnapshot, isCurrent]);
  useEffect(() => {
    articleRequest.current += 1;
    fullTextRequest.current += 1;
    coverRequest.current += 1;
    progressState.current = { articleId: null, progress: 0, revision: 0 };
    setSelectedArticleId(null); setSelectedArticle(null); setHighlights([]); setFullText(null); setShowFullText(false); setCoverDataUrl(null); setCoverBusy(false); setCoverError(null); setProgress(0);
    if (active) void loadArticles();
  }, [active, loadArticles]);

  const selectArticle = useCallback(async (articleId: string) => {
    const sequence = ++articleRequest.current;
    fullTextRequest.current += 1;
    coverRequest.current += 1;
    progressState.current = { articleId, progress: 0, revision: 0 };
    setSelectedArticleId(articleId); setArticleLoading(true); setFullTextBusy(false); setFullText(null); setShowFullText(false); setCoverDataUrl(null); setCoverBusy(false); setCoverError(null); setError(null); setProgress(0);
    try {
      const [article, nextHighlights, savedProgress] = await Promise.all([gateway.getArticle(articleId), gateway.listHighlights(articleId), gateway.getReadingProgress(articleId)]);
      if (sequence !== articleRequest.current) return;
      const nextProgress = savedProgress?.progress ?? 0;
      const nextRevision = savedProgress?.revision ?? 0;
      progressState.current = { articleId, progress: nextProgress, revision: nextRevision };
      setSelectedArticle(article); setHighlights(nextHighlights); setProgress(nextProgress);
    }
    catch (caught) { if (sequence === articleRequest.current) { setSelectedArticle(null); setError(messageFrom(caught)); } }
    finally { if (sequence === articleRequest.current) setArticleLoading(false); }
  }, [gateway]);

  useEffect(() => { try { localStorage.setItem(RSS_READING_STYLE_STORAGE_KEY, JSON.stringify(readingStyle)); } catch { /* local style is best effort */ } }, [readingStyle]);

  const refresh = useCallback(async (feedId?: string, force = true) => {
    const generation = lifecycleGenerationRef.current;
    if (!isCurrent(generation)) return;
    await runRssRefreshExclusive(gateway, async () => {
      if (!isCurrent(generation)) return undefined;
      setError(null);
      try {
        const refreshResult = feedId ? await gateway.refreshFeed(feedId, force) : await gateway.refreshAll(force);
        if (!isCurrent(generation)) return undefined;
        coverCache.current.clear();
        if (force) setStatus(refreshResult.statusText != null ? rawMessage(refreshResult.statusText) : localMessage("刷新完成：成功 {successCount}、失败 {failureCount}", { successCount: refreshResult.successCount, failureCount: refreshResult.failureCount }));
        await Promise.all([refreshViewRef.current.loadSnapshot(), refreshViewRef.current.loadArticles()]);
        const latestPreferences = refreshViewRef.current.preferences;
        if (isCurrent(generation) && latestPreferences.offlineTranslationCacheEnabled && latestPreferences.automaticLocalPretranslationOnRefreshEnabled) setRefreshEnqueue({ id: Date.now(), feedId });
        return refreshResult;
      } catch (caught) { if (isCurrent(generation)) setError(messageFrom(caught)); return undefined; }
    });
  }, [gateway, isCurrent]);

  const automaticRefreshRef = useRef<() => void>(() => undefined);
  automaticRefreshRef.current = () => { void refresh(undefined, false); };
  useEffect(() => {
    if (!active || !preferencesLoaded || !preferences.backgroundRefreshEnabled) return;
    const id = window.setInterval(() => automaticRefreshRef.current(), preferences.backgroundRefreshIntervalMinutes * 60_000);
    return () => window.clearInterval(id);
  }, [active, gateway, preferencesLoaded, preferences.backgroundRefreshEnabled, preferences.backgroundRefreshIntervalMinutes]);

  const updateArticle = async (articleId: string, change: { readAt?: number | null; isStarred?: boolean; tags?: string[] }) => {
    try {
      const next = await gateway.updateArticleState({ articleId, ...change });
      setArticles((current) => current.map((article) => article.id === articleId ? next : article));
      setSelectedArticle((current) => current?.id === articleId ? { ...current, ...next } : current);
      await loadSnapshot();
    } catch (caught) { setError(messageFrom(caught)); }
  };

  const markAllRead = async () => {
    try { const result = await gateway.markAllRead({ scope, searchText, unreadOnly, author, tag }); const changed = typeof result === "number" ? result : result.changedCount; const message = localMessage("已标记 {count} 篇文章为已读。", { count: changed }); if (typeof result !== "number" && result.undoToken) setUndo({ token: result.undoToken, kind: "read", message }); setStatus(message); await Promise.all([loadSnapshot(), loadArticles()]); }
    catch (caught) { setError(messageFrom(caught)); }
  };

  const saveAdd = async (discoverHomepage: boolean) => {
    const value = address.trim(); if (!value) return;
    setError(null);
    if (discoverHomepage) {
      try { const candidates = await gateway.discover(value); setDiscovered(candidates); setSelectedDiscovery(new Set(candidates.slice(0, 1))); if (!candidates.length) setStatus(localMessage("没有发现订阅地址；可以直接将此地址作为订阅添加。")); return; }
      catch (caught) { setError(messageFrom(caught)); return; }
    }
    try { const feed = await gateway.addFeed({ url: value }); setAddress(""); setDialog(null); await refresh(feed.id); }
    catch (caught) { setError(messageFrom(caught)); }
  };

  const addDiscovered = async () => {
    try { for (const url of selectedDiscovery) await gateway.addFeed({ url }); setDialog(null); setAddress(""); setDiscovered([]); await refresh(); }
    catch (caught) { setError(messageFrom(caught)); }
  };

  const removeFeed = async (feed: RssFeed) => {
    if (!window.confirm(t("删除“{title}”及其本地文章缓存？", { title: feed.title }))) return;
    try { const result = await gateway.removeFeed(feed.id); const message = localMessage("已删除“{title}”。", { title: feed.title }); if (result && result.undoToken) setUndo({ token: result.undoToken, kind: "feed", message }); if (typeof scope === "object" && scope.feed === feed.id) setScope("all"); setStatus(message); await Promise.all([loadSnapshot(), loadArticles()]); }
    catch (caught) { setError(messageFrom(caught)); }
  };

  const editFeed = async (feed: RssFeed) => {
    const newUrl = window.prompt(t("编辑 RSS / Atom 地址"), feed.url); if (!newUrl || newUrl === feed.url) return;
    try { await gateway.updateFeedUrl(feed.id, newUrl); setStatus(localMessage("订阅地址已更新，本地文章状态已保留。")); await loadSnapshot(); }
    catch (caught) { setError(messageFrom(caught)); }
  };

  const savePreferences = async () => { try { setPreferences(await gateway.updatePreferences(preferences)); await loadOfflineTranslationStatus(); setStatus(localMessage("RSS 偏好已保存。")); } catch (caught) { setError(messageFrom(caught)); } };
  const pruneOfflineTranslations = async () => { try { const result = await gateway.pruneOfflineTranslations(); await loadOfflineTranslationStatus(); setStatus(localMessage("已清理 {count} 条过期离线译文。", { count: result.removedCount })); } catch (caught) { setError(messageFrom(caught)); } };
  const clearOfflineTranslations = async () => { if (!window.confirm(t("清空所有持久化离线译文？此操作不可撤销。"))) return; try { await gateway.clearOfflineTranslations(null); await loadOfflineTranslationStatus(); setStatus(localMessage("已清空持久化离线译文。")); } catch (caught) { setError(messageFrom(caught)); } };
  const prune = async () => { if (!window.confirm(t("清理符合保留策略的过期已读文章？收藏与标注文章会被保留。"))) return; try { const result = await gateway.prune(); setStatus(localMessage("已清理 {count} 篇过期已读文章。", { count: result.removedArticleCount })); await Promise.all([loadSnapshot(), loadArticles()]); } catch (caught) { setError(messageFrom(caught)); } };
  const fetchFullText = async (force: boolean) => {
    if (!selectedArticle) return;
    const articleId = selectedArticle.id;
    const sequence = ++fullTextRequest.current;
    setFullTextBusy(true);
    try {
      const record = await gateway.fetchFullText(articleId, force);
      if (sequence !== fullTextRequest.current || progressState.current.articleId !== articleId) return;
      setFullText(record);
      if (record.status === "ready") { setShowFullText(true); setStatus(localMessage("已缓存原网页全文。")); }
      else setError(record.failureMessage != null ? rawMessage(record.failureMessage) : localMessage("全文提取未通过质量检查。"));
    } catch (caught) {
      if (sequence === fullTextRequest.current) setError(messageFrom(caught));
    } finally {
      if (sequence === fullTextRequest.current) setFullTextBusy(false);
    }
  };
  useEffect(() => {
    if (!active || !preferences.automaticFullTextExtractionEnabled || !selectedArticle || fullText) return;
    const articleId = selectedArticle.id;
    const sequence = ++fullTextRequest.current;
    void gateway.fetchFullText(articleId, false).then((record) => {
      if (sequence === fullTextRequest.current && progressState.current.articleId === articleId) {
        setFullText(record);
        if (record.status === "ready") setShowFullText(true);
      }
    }).catch(() => undefined);
  }, [active, gateway, fullText, preferences.automaticFullTextExtractionEnabled, selectedArticle]);
  useEffect(() => {
    const sequence = ++coverRequest.current;
    setCoverDataUrl(null); setCoverBusy(false); setCoverError(null);
    if (!active || !preferences.remoteImagesEnabled || !selectedArticle?.coverUrl) return;
    const articleId = selectedArticle.id;
    const cacheKey = `${articleId}\n${selectedArticle.coverUrl}`;
    const cached = coverCache.current.get(cacheKey);
    if (cached) { coverCache.current.delete(cacheKey); coverCache.current.set(cacheKey, cached); setCoverDataUrl(cached); return; }
    setCoverBusy(true);
    void gateway.fetchCover(articleId).then((dataUrl) => {
      if (sequence !== coverRequest.current || progressState.current.articleId !== articleId) return;
      if (dataUrl) {
        if (coverCache.current.size >= RSS_COVER_CACHE_LIMIT) {
          const oldest = coverCache.current.keys().next().value;
          if (oldest) coverCache.current.delete(oldest);
        }
        coverCache.current.set(cacheKey, dataUrl); setCoverDataUrl(dataUrl);
      }
    }).catch(() => { if (sequence === coverRequest.current) setCoverError(localMessage("封面未加载：源站响应未通过远端图片安全检查。")); }).finally(() => { if (sequence === coverRequest.current) setCoverBusy(false); });
  }, [active, gateway, preferences.remoteImagesEnabled, selectedArticle?.coverUrl, selectedArticle?.id]);
  const saveHighlight = async (text: string, note: string, values: string[]) => { if (!selectedArticle) return; try { const saved = await gateway.saveHighlight({ articleId: selectedArticle.id, text, note, tags: values }); setHighlights((current) => [saved, ...current.filter((item) => item.id !== saved.id)]); setStatus(localMessage("高亮已保存。")); } catch (caught) { setError(messageFrom(caught)); } };
  const deleteHighlight = async (id: string) => { try { await gateway.deleteHighlight(id); setHighlights((current) => current.filter((item) => item.id !== id)); } catch (caught) { setError(messageFrom(caught)); } };
  const persistProgress = async (next: number) => {
    if (!selectedArticle) return;
    const previous = progressState.current;
    if (previous.articleId !== selectedArticle.id || !shouldPersistReadingProgress(previous.progress, next)) return;
    const revision = previous.revision + 1;
    progressState.current = { articleId: selectedArticle.id, progress: next, revision };
    setProgress(next);
    try {
      await gateway.saveReadingProgress({ articleId: selectedArticle.id, progress: next, revision });
      if (preferences.automaticMarkReadAtEndEnabled && !selectedArticle.readAt && didReachReadingCompletion(next) && !didReachReadingCompletion(previous.progress)) await updateArticle(selectedArticle.id, { readAt: Math.floor(Date.now() / 1000) });
    } catch (caught) { setError(messageFrom(caught)); }
  };
  const runUndo = async () => { if (!undo) return; try { if (undo.kind === "feed") await gateway.undoRemoveFeed(undo.token); else await gateway.undoMarkAllRead(undo.token); setUndo(null); await Promise.all([loadSnapshot(), loadArticles()]); } catch (caught) { setError(messageFrom(caught)); } };
  const exportBackup = async () => { try { setBackupText(await gateway.exportBackup()); setBackupInfo(localMessage("备份已导出到文本框；请保存为私密文件。")); } catch (caught) { setError(messageFrom(caught)); } };
  const inspectBackup = async () => { try { const value = await gateway.inspectBackup(backupText); setBackupInfo(localMessage("备份有效：{feedCount} 个订阅、{articleCount} 篇文章、{highlightCount} 条高亮。", { feedCount: value.feedCount, articleCount: value.articleCount, highlightCount: value.highlightCount })); } catch (caught) { setError(messageFrom(caught)); } };
  const restoreBackup = async () => { if (!window.confirm(t("恢复备份会替换当前 RSS 本地数据，是否继续？"))) return; try { const value = await gateway.restoreBackup(backupText); setBackupInfo(localMessage("已恢复备份：{count} 篇文章。", { count: value.articleCount })); await Promise.all([loadSnapshot(), loadArticles()]); } catch (caught) { setError(messageFrom(caught)); } };
  const selectedFeed = selectedArticle ? feeds.find((feed) => feed.id === selectedArticle.feedId) ?? null : null;
  const selectedPlainText = selectedArticle ? rssArticlePlainText(selectedArticle, fullText?.status === "ready" ? fullText.plainText : "") : "";
  const saveToKnowledge = async () => { if (!selectedArticle || !onSaveToKnowledge) return; try { await onSaveToKnowledge({ article: selectedArticle, feed: selectedFeed, text: selectedPlainText }); setStatus(localMessage("文章已保存到本地资料库。")); } catch (caught) { setError(messageFrom(caught)); } };
  const insertReference = async (text = selectedPlainText) => { if (!selectedArticle || !onInsertReference) return; try { await onInsertReference({ article: selectedArticle, feed: selectedFeed, text }); setStatus(localMessage("RSS 文章已保存到资料库，并插入安全来源链接。")); } catch (caught) { setError(messageFrom(caught)); } };
  const createInspirationDraft = async () => { if (!selectedArticle || !onCreateInspirationDraft) return; try { await onCreateInspirationDraft({ article: selectedArticle, feed: selectedFeed, text: selectedPlainText }); } catch (caught) { setError(messageFrom(caught)); } };
  const toggleArticleSelection = (articleId: string, checked: boolean) => {
    if (checked && !selectedArticleIds.has(articleId) && selectedArticleIds.size >= 100) { setError(localMessage("一次最多选择 100 篇文章保存到资料库。")); return; }
    setSelectedArticleIds((current) => {
    const next = new Set(current);
    if (!checked) { next.delete(articleId); return next; }
    next.add(articleId);
    return next;
    });
  };
  const toggleVisibleArticleSelection = (checked: boolean) => {
    const available = Math.max(0, 100 - selectedArticleIds.size);
    const unselectedVisible = visibleArticles.filter((article) => !selectedArticleIds.has(article.id));
    if (checked && unselectedVisible.length > available) setStatus(localMessage("已按 100 篇上限选择可保存文章。"));
    setSelectedArticleIds((current) => {
    const next = checked ? new Set(current) : new Set([...current].filter((id) => !visibleArticles.some((article) => article.id === id)));
    if (!checked) return next;
    for (const article of visibleArticles) {
      if (next.size >= 100) break;
      next.add(article.id);
    }
    return next;
    });
  };
  const saveSelectedToKnowledge = async () => {
    if (!onSaveToKnowledge || batchSaving) return;
    const articleIds = [...selectedArticleIds].slice(0, 100);
    if (!articleIds.length) return;
    setBatchSaving(true); setError(null);
    let succeeded = 0; let failed = 0; const savedIds: string[] = [];
    for (const articleId of articleIds) {
      try {
        const article = await gateway.getArticle(articleId);
        if (!article) throw new Error("文章已不存在。");
        const feed = feeds.find((item) => item.id === article.feedId) ?? null;
        await onSaveToKnowledge({ article, feed, text: rssArticlePlainText(article) });
        succeeded += 1; savedIds.push(articleId);
      } catch { failed += 1; }
    }
    setSelectedArticleIds((current) => new Set([...current].filter((id) => !savedIds.includes(id))));
    setBatchSaving(false);
    setStatus(failed ? localMessage("已保存 {succeeded} 篇文章到资料库；{failed} 篇未保存。", { succeeded, failed }) : localMessage("已保存 {succeeded} 篇文章到资料库。", { succeeded }));
  };
  useEffect(() => { const onKey = (event: KeyboardEvent) => { if (!active || event.metaKey || event.ctrlKey || event.altKey || (event.target instanceof HTMLInputElement) || (event.target instanceof HTMLTextAreaElement)) return; if (event.key === "/") { event.preventDefault(); document.querySelector<HTMLInputElement>(".rss-filters input[aria-label]")?.focus(); } if (event.key === "r") { event.preventDefault(); void refresh(); } if (selectedArticle) { if (event.key === "m") void updateArticle(selectedArticle.id, { readAt: selectedArticle.readAt ? null : Math.floor(Date.now() / 1000) }); if (event.key === "s") void updateArticle(selectedArticle.id, { isStarred: !selectedArticle.isStarred }); const index = visibleArticles.findIndex((item) => item.id === selectedArticle.id); if (event.key === "j" && visibleArticles[index + 1]) void selectArticle(visibleArticles[index + 1].id); if (event.key === "k" && visibleArticles[index - 1]) void selectArticle(visibleArticles[index - 1].id); } }; window.addEventListener("keydown", onKey); return () => window.removeEventListener("keydown", onKey); }, [active, selectedArticle, visibleArticles, refresh]);

  if (!active) return null;
  return <section className="rss-reader" aria-label={t("RSS 阅读器")}>
    <aside className="rss-sidebar" aria-label={t("RSS 订阅侧栏")}>
      <header><div><h2>{t("订阅")}</h2><p>{t("{feedCount} 个订阅 · {unreadCount} 篇未读", { feedCount: formatNumber(feeds.length, locale), unreadCount: formatNumber(libraryCounts.unreadCount, locale) })}</p></div><button type="button" className="rss-icon-button" onClick={() => { setDialog("add"); setDiscovered([]); }} aria-label={t("添加 RSS 或 Atom 订阅")}>＋</button></header>
      <div className="rss-sidebar-actions"><button type="button" onClick={() => void refresh()} disabled={refreshing || !feeds.length}>{t(refreshing ? "刷新中…" : "刷新全部")}</button>{translationGateway && <button type="button" onClick={() => setDialog("translation")}>{t("批量翻译")}</button>}<button type="button" onClick={() => setDialog("history")}>{t("历史补全队列")}</button><button type="button" onClick={() => setDialog("opml")}>OPML</button><button type="button" onClick={() => setDialog("backup")}>{t("备份")}</button><button type="button" onClick={() => { setDialog("preferences"); void loadOfflineTranslationStatus(); }}>{t("偏好")}</button></div>
      <nav aria-label={t("阅读范围")}><ScopeButton selected={scope === "all"} label={t("全部文章")} count={libraryCounts.articleCount} onClick={() => setScope("all")} /><ScopeButton selected={scope === "unread"} label={t("未读")} count={libraryCounts.unreadCount} onClick={() => setScope("unread")} /><ScopeButton selected={scope === "starred"} label={t("稍后阅读")} count={libraryCounts.starredCount} onClick={() => setScope("starred")} /></nav>
      <h3>{t("我的订阅")}</h3>
      <ul className="rss-feed-list">{feeds.map((feed) => <li key={feed.id}><button type="button" className={`rss-feed ${typeof scope === "object" && scope.feed === feed.id ? "selected" : ""}`} onClick={() => setScope({ feed: feed.id })}><span className={`rss-health ${feedHealth(feed)}`} aria-label={healthLabel(feed, t)} /> <span className="rss-feed-name">{feed.title}</span><span className="rss-count">{formatNumber(libraryCounts.unreadCountByFeed[feed.id] ?? 0, locale)}</span></button><div className="rss-feed-controls"><button type="button" onClick={() => void refresh(feed.id)} disabled={refreshing} aria-label={t("刷新 {title}", { title: feed.title })}>↻</button><button type="button" className="rss-history-button" onClick={() => setHistoryFeedId(feed.id)}>{t("补全历史文章")}</button><button type="button" onClick={() => void editFeed(feed)} aria-label={t("编辑 {title} 地址", { title: feed.title })}>✎</button><button type="button" onClick={() => void removeFeed(feed)} aria-label={t("删除 {title}", { title: feed.title })}>×</button></div>{feed.lastIssue && <p className="rss-feed-issue" role="status">{feed.lastIssue.userMessage}</p>}</li>)}</ul>
    </aside>
    <main className="rss-content">
      <header className="rss-toolbar"><div><h1>{localizedScopeLabel(scope, feeds, t)}</h1><p>{t("{count} 篇文章", { count: formatNumber(totalCount, locale) })}</p></div><div className="rss-toolbar-actions"><button type="button" onClick={() => void markAllRead()} disabled={totalCount === 0}>{t("全部标为已读")}</button>{onSaveToKnowledge && <><label className="rss-batch-toggle"><input type="checkbox" checked={visibleArticles.length > 0 && visibleArticles.every((article) => selectedArticleIds.has(article.id))} onChange={(event) => toggleVisibleArticleSelection(event.target.checked)} /> {t("选择当前页")}</label><button type="button" onClick={() => void saveSelectedToKnowledge()} disabled={!selectedArticleIds.size || batchSaving}>{batchSaving ? t("保存中…") : t("保存选中（{count}）", { count: formatNumber(selectedArticleIds.size, locale) })}</button></>}</div></header>
      {(status || error) && <div className={`rss-notice ${error ? "error" : ""}`} role={error ? "alert" : "status"}>{renderReaderMessage((error ?? status)!, t, locale)}<button type="button" aria-label={t("关闭提示")} onClick={() => { setError(null); setStatus(null); }}>×</button></div>}
      <div className="rss-filters" aria-label={t("文章筛选与排序")}><input value={searchText} onChange={(event) => setSearchText(event.target.value)} placeholder={t("搜索标题或正文")} aria-label={t("搜索文章标题或正文")} /><label><input type="checkbox" checked={unreadOnly} onChange={(event) => setUnreadOnly(event.target.checked)} /> {t("只看未读")}</label><select value={author ?? ""} onChange={(event) => setAuthor(event.target.value || null)} aria-label={t("按作者筛选")}><option value="">{t("全部作者")}</option>{availableAuthors.map((value) => <option key={value}>{value}</option>)}</select><select value={tag ?? ""} onChange={(event) => setTag(event.target.value || null)} aria-label={t("按标签筛选")}><option value="">{t("全部标签")}</option>{availableTags.map((value) => <option key={value}>{value}</option>)}</select><select value={sort} onChange={(event) => setSort(event.target.value as RssSortOrder)} aria-label={t("排序")}><option value="newest">{t("最新优先")}</option><option value="oldest">{t("最早优先")}</option></select></div>
      <div className="rss-reader-grid"><section className="rss-article-list" aria-label={t("RSS 文章列表")}>{loading && !articles.length ? <p className="rss-empty" role="status">{t("正在读取文章…")}</p> : visibleArticles.length ? <>{visibleArticles.map((article) => <ArticleRow key={article.id} article={article} selected={article.id === selectedArticleId} batchSelected={selectedArticleIds.has(article.id)} batchSelectionEnabled={Boolean(onSaveToKnowledge)} onSelect={() => void selectArticle(article.id)} onToggleSelected={(checked) => toggleArticleSelection(article.id, checked)} onToggleRead={() => void updateArticle(article.id, { readAt: article.readAt ? null : Math.floor(Date.now() / 1000) })} onToggleStar={() => void updateArticle(article.id, { isStarred: !article.isStarred })} />)}{hasMore && <button type="button" className="rss-load-more" onClick={() => void loadArticles(articles.length, true)} disabled={loading}>{t(loading ? "正在加载…" : "加载更多文章")}</button>}</> : <p className="rss-empty">{t("没有符合当前筛选条件的文章。")}</p>}</section><ArticleReader article={selectedArticle} loading={articleLoading} selectedId={selectedArticleId} feed={selectedFeed ?? undefined} fullText={fullText} showFullText={showFullText} fullTextBusy={fullTextBusy} coverDataUrl={coverDataUrl} coverBusy={coverBusy} coverError={coverError} highlights={highlights} progress={progress} preferences={preferences} style={readingStyle} rssGateway={gateway} translationGateway={translationGateway} sessionCache={translationSessionCache.current} cacheRevision={cacheRevision} onStyle={setReadingStyle} onProgress={persistProgress} onFetchFullText={fetchFullText} onShowFullText={() => setShowFullText((value) => !value)} onSaveHighlight={saveHighlight} onDeleteHighlight={deleteHighlight} onSaveToKnowledge={onSaveToKnowledge ? saveToKnowledge : undefined} onInsertReference={onInsertReference ? insertReference : undefined} onCreateInspirationDraft={onCreateInspirationDraft ? createInspirationDraft : undefined} onToggleRead={() => selectedArticle && void updateArticle(selectedArticle.id, { readAt: selectedArticle.readAt ? null : Math.floor(Date.now() / 1000) })} onToggleStar={() => selectedArticle && void updateArticle(selectedArticle.id, { isStarred: !selectedArticle.isStarred })} onTags={(values) => selectedArticle && void updateArticle(selectedArticle.id, { tags: values })} /></div>
    </main>
    {dialog === "add" && <Modal title={t("添加 RSS / Atom 订阅")} onClose={() => setDialog(null)}><label>{t("订阅地址或主页地址")}<input autoFocus value={address} onChange={(event) => setAddress(event.target.value)} placeholder="https://example.com/feed.xml" /></label>{discovered.length > 0 && <fieldset><legend>{t("发现的订阅")}</legend>{discovered.map((url) => <label key={url}><input type="checkbox" checked={selectedDiscovery.has(url)} onChange={(event) => setSelectedDiscovery((current) => { const next = new Set(current); event.target.checked ? next.add(url) : next.delete(url); return next; })} /> {url}</label>)}</fieldset>}<div className="rss-modal-actions">{discovered.length ? <button type="button" onClick={() => void addDiscovered()} disabled={!selectedDiscovery.size}>{t("添加选中订阅")}</button> : <><button type="button" onClick={() => void saveAdd(false)}>{t("直接添加地址")}</button><button type="button" onClick={() => void saveAdd(true)}>{t("发现主页订阅")}</button></>}<button type="button" onClick={() => setDialog(null)}>{t("取消")}</button></div></Modal>}
    {dialog === "opml" && <RssOpmlPrivacyDialog gateway={gateway} onClose={() => setDialog(null)} onChanged={() => Promise.all([loadSnapshot(), loadArticles()]).then(() => undefined)} />}
    {dialog === "history" && <RssHistoryQueueDialog gateway={gateway} feeds={feeds} onClose={() => setDialog(null)} onOpen={(feedId) => { setDialog(null); setHistoryFeedId(feedId); }} />}
    {historyFeedId && feeds.find((feed) => feed.id === historyFeedId) && <RssHistoryBackfillDialog feed={feeds.find((feed) => feed.id === historyFeedId)!} gateway={gateway} onClose={() => setHistoryFeedId(null)} onChanged={() => Promise.all([loadSnapshot(), loadArticles()]).then(() => undefined)} />}
    {dialog === "preferences" && <Modal title={t("RSS 偏好与清理")} onClose={() => setDialog(null)}><PreferenceControls preferences={preferences} onChange={setPreferences} /><p className="rss-help">{t("清理只会删除过期、已读、未收藏且无标注的文章。")}</p><section className="rss-offline-translation-preferences"><p>{offlineTranslationStatus ? <>{t("离线译文：{count} 条，{used} / {maximum} MiB", { count: formatNumber(offlineTranslationStatus.entryCount, locale), used: formatSizeMiB(offlineTranslationStatus.totalBytes, locale), maximum: formatSizeMiB(offlineTranslationStatus.maxBytes, locale) })}{offlineTranslationStatus.expiredCount ? t("，其中 {count} 条已过期", { count: formatNumber(offlineTranslationStatus.expiredCount, locale) }) : ""}</> : t("正在读取状态…")}</p><p className="rss-help">{t("译文是可清理的派生缓存，不包含在 RSS 备份中；翻译索引不会保存原文、术语表或服务地址。")}</p><button type="button" onClick={() => void loadOfflineTranslationStatus()}>{t("刷新译文状态")}</button><button type="button" onClick={() => void pruneOfflineTranslations()}>{t("清理过期译文")}</button><button type="button" onClick={() => void clearOfflineTranslations()}>{t("清空全部译文")}</button></section><div className="rss-modal-actions"><button type="button" onClick={() => void savePreferences()}>{t("保存偏好")}</button><button type="button" onClick={() => void prune()}>{t("立即清理")}</button></div></Modal>}
    {dialog === "backup" && <Modal title={t("RSS 备份与恢复")} onClose={() => setDialog(null)}><p>{t("备份文本包含本机 RSS 数据；请只保存到可信位置。")}</p><textarea value={backupText} onChange={(event) => setBackupText(event.target.value)} rows={12} aria-label={t("RSS 备份文本")} />{backupInfo && <p className="rss-help">{renderReaderMessage(backupInfo, t, locale)}</p>}<div className="rss-modal-actions"><button type="button" onClick={() => void exportBackup()}>{t("导出备份")}</button><button type="button" onClick={() => void inspectBackup()} disabled={!backupText}>{t("检查备份")}</button><button type="button" onClick={() => void restoreBackup()} disabled={!backupText}>{t("恢复备份")}</button></div></Modal>}
    {translationGateway && <RssBatchTranslationDialog open={dialog === "translation"} onOpen={() => setDialog("translation")} onClose={() => setDialog((current) => current === "translation" ? null : current)} feeds={feeds} rssGateway={gateway} translationGateway={translationGateway} sessionCache={translationSessionCache.current} onCacheChange={onTranslationCacheChange} offlineTranslationGateway={gateway} offlineTranslationEnabled={preferences.offlineTranslationCacheEnabled} refreshEnqueue={refreshEnqueue} />}
    {undo && <div className="rss-undo" role="status">{renderReaderMessage(undo.message, t, locale)}<button type="button" onClick={() => void runUndo()}>{t("撤销")}</button><button type="button" aria-label={t("关闭撤销提示")} onClick={() => setUndo(null)}>×</button></div>}
  </section>;
}

function ScopeButton({ selected, label, count, onClick }: { selected: boolean; label: string; count: number; onClick: () => void }) { const { locale } = useI18n(rssMessages); return <button type="button" className={`rss-scope ${selected ? "selected" : ""}`} aria-current={selected ? "page" : undefined} onClick={onClick}><span>{label}</span><span>{formatNumber(count, locale)}</span></button>; }
function ArticleRow({ article, selected, batchSelected, batchSelectionEnabled, onSelect, onToggleSelected, onToggleRead, onToggleStar }: { article: RssArticleHeader; selected: boolean; batchSelected: boolean; batchSelectionEnabled: boolean; onSelect: () => void; onToggleSelected: (checked: boolean) => void; onToggleRead: () => void; onToggleStar: () => void }) { const { locale, t } = useI18n(rssMessages); return <article className={`rss-row ${selected ? "selected" : ""}`}><button type="button" className="rss-row-main" onClick={onSelect} aria-current={selected ? "true" : undefined}><span className={article.readAt ? "rss-read-dot read" : "rss-read-dot"} aria-label={t(article.readAt ? "已读" : "未读")} /><span className="rss-row-copy"><strong>{article.title}</strong><small>{article.author ? `${article.author} · ` : ""}{formatDate(article.publishedAt ?? article.fetchedAt, locale)}</small><p>{article.readableSummary}</p>{article.tags.length > 0 && <em>{article.tags.join(" · ")}</em>}</span></button><div className="rss-row-actions">{batchSelectionEnabled && <label className="rss-row-select"><input type="checkbox" checked={batchSelected} onChange={(event) => onToggleSelected(event.target.checked)} aria-label={t("选择 {title}", { title: article.title })} /></label>}<button type="button" onClick={onToggleRead} aria-label={t(article.readAt ? "标为未读" : "标为已读")}>{article.readAt ? "○" : "●"}</button><button type="button" onClick={onToggleStar} aria-label={t(article.isStarred ? "取消稍后阅读" : "加入稍后阅读")}>{article.isStarred ? "★" : "☆"}</button></div></article>; }
function ArticleReader({ article, loading, selectedId, feed, fullText, showFullText, fullTextBusy, coverDataUrl, coverBusy, coverError, highlights, progress, preferences, style, rssGateway, translationGateway, sessionCache, cacheRevision, onStyle, onProgress, onFetchFullText, onShowFullText, onSaveHighlight, onDeleteHighlight, onSaveToKnowledge, onInsertReference, onCreateInspirationDraft, onToggleRead, onToggleStar, onTags }: { article: RssArticle | null; loading: boolean; selectedId: string | null; feed?: RssFeed; fullText: RssFullTextRecord | null; showFullText: boolean; fullTextBusy: boolean; coverDataUrl: string | null; coverBusy: boolean; coverError: ReaderMessage | null; highlights: RssHighlight[]; progress: number; preferences: RssPreferences; style: RssReadingStyle; rssGateway: RssGateway; translationGateway?: RssReaderProps["translationGateway"]; sessionCache: TranslationSessionCache; cacheRevision: number; onStyle: (style: RssReadingStyle) => void; onProgress: (value: number) => void; onFetchFullText: (force: boolean) => void; onShowFullText: () => void; onSaveHighlight: (text: string, note: string, tags: string[]) => void; onDeleteHighlight: (id: string) => void; onSaveToKnowledge?: () => void; onInsertReference?: (text?: string) => void; onCreateInspirationDraft?: () => void; onToggleRead: () => void; onToggleStar: () => void; onTags: (values: string[]) => void }) {
  const { locale, t } = useI18n(rssMessages);
  const [tags, setTags] = useState("");
  const [highlightText, setHighlightText] = useState("");
  const [note, setNote] = useState("");
  const [selectionText, setSelectionText] = useState("");
  const [translationActivation, setTranslationActivation] = useState<{ id: number; scope: "article" | "selection" }>();
  const [articleTranslation, setArticleTranslation] = useState<TextTranslationResult | null>(null);
  const [articleTranslationSourceKey, setArticleTranslationSourceKey] = useState<string | null>(null);
  const [articleTranslationView, setArticleTranslationView] = useState<ArticleTranslationView>("original");
  const [programmaticParagraph, setProgrammaticParagraph] = useState<{ id: string; sourceText: string } | null>(null);
  const [paragraphOverrides, setParagraphOverrides] = useState<Record<string, string>>({});
  const [speech, setSpeech] = useState<"idle" | "speaking" | "paused">("idle");
  const [rate, setRate] = useState(1);
  const translationActivationID = useRef(0);
  const speechGeneration = useRef(0);
  const articleTranslationState = useRef<{ sourceKey: string; resultKey: string | null }>({ sourceKey: "", resultKey: null });
  const articleTranslationSource = useRef("");
  const articleTranslationRequestKey = useRef<string | null>(null);
  const programmaticParagraphRef = useRef<{ id: string; sourceText: string } | null>(null);
  const fullTextReady = fullText?.status === "ready" && Boolean(fullText.contentHtml);
  const articleText = article ? fullTextReady && showFullText ? fullText.plainText : rssArticlePlainText(article) : "";
  const sourceHtml = sanitizeArticleHtml(fullTextReady && showFullText ? fullText.contentHtml : article?.contentHtml || article?.summaryHtml || article?.webPageSnapshotHtml || "");
  const structuredHtmlPlan = useMemo(() => {
    if (!article) return null;
    try {
      return buildStructuredHtmlTranslationPlan({ title: article.title, html: sourceHtml, maxTextBytes: 60 * 1024 });
    } catch {
      return null;
    }
  }, [article, sourceHtml]);
  const currentArticleTranslationSourceKey = JSON.stringify([article?.id ?? selectedId ?? null, fullTextReady && showFullText ? "full-text" : "feed", article?.title ?? "", sourceHtml, articleText]);
  articleTranslationSource.current = currentArticleTranslationSourceKey;

  const clearReadingSelection = useCallback(() => {
    window.getSelection()?.removeAllRanges();
    setHighlightText("");
    setSelectionText("");
    setNote("");
  }, []);

  const stopSpeech = useCallback(() => {
    speechGeneration.current += 1;
    window.speechSynthesis?.cancel();
    setSpeech("idle");
  }, []);

  useEffect(() => () => {
    speechGeneration.current += 1;
    window.speechSynthesis?.cancel();
  }, []);

  const onArticleTranslationChange = useCallback((next: TextTranslationResult | null, requestKey: string) => {
    const sourceKey = articleTranslationSource.current;
    const resultKey = next ? translationResultKey(next) : null;
    const nextRequestKey = next ? requestKey : null;
    if (!next && articleTranslationState.current.sourceKey === sourceKey && articleTranslationState.current.resultKey === null && articleTranslationRequestKey.current === null) return;
    const didChangeWholeTranslation = articleTranslationState.current.sourceKey !== sourceKey
      || articleTranslationState.current.resultKey !== resultKey
      || articleTranslationRequestKey.current !== nextRequestKey;
    articleTranslationState.current = { sourceKey, resultKey };
    articleTranslationRequestKey.current = nextRequestKey;
    setArticleTranslation(next);
    setArticleTranslationSourceKey(next ? sourceKey : null);
    setArticleTranslationView(next ? "translation" : "original");
    if (didChangeWholeTranslation) {
      programmaticParagraphRef.current = null;
      setProgrammaticParagraph(null);
      setParagraphOverrides({});
    }
    stopSpeech();
    clearReadingSelection();
  }, [clearReadingSelection, stopSpeech]);

  const toggleArticleTranslation = useCallback(() => {
    if (!articleTranslationState.current.resultKey || articleTranslationState.current.sourceKey !== articleTranslationSource.current) return;
    stopSpeech();
    setArticleTranslationView((view) => view === "original" ? "translation" : "original");
    clearReadingSelection();
  }, [clearReadingSelection, stopSpeech]);

  const setTranslationView = useCallback((view: ArticleTranslationView) => {
    if (!articleTranslationState.current.resultKey || articleTranslationState.current.sourceKey !== articleTranslationSource.current) return;
    stopSpeech();
    setArticleTranslationView(view);
    clearReadingSelection();
  }, [clearReadingSelection, stopSpeech]);

  useEffect(() => {
    setTags(article?.tags.join(", ") ?? "");
    clearReadingSelection();
    setTranslationActivation(undefined);
    stopSpeech();
  }, [selectedId, article?.id, article?.tags, clearReadingSelection, fullText?.plainText, showFullText, stopSpeech]);

  // The panel restores a matching session-cache entry after this reset. Until
  // then, the source key prevents an old article or body version from flashing.
  useEffect(() => {
    if (articleTranslationState.current.sourceKey === currentArticleTranslationSourceKey) return;
    articleTranslationState.current = { sourceKey: currentArticleTranslationSourceKey, resultKey: null };
    setArticleTranslation(null);
    setArticleTranslationSourceKey(null);
    setArticleTranslationView("original");
    programmaticParagraphRef.current = null;
    articleTranslationRequestKey.current = null;
    setProgrammaticParagraph(null);
    setParagraphOverrides({});
  }, [currentArticleTranslationSourceKey]);

  const currentArticleTranslation = articleTranslationSourceKey === currentArticleTranslationSourceKey ? articleTranslation : null;
  const showingArticleTranslation = Boolean(currentArticleTranslation && articleTranslationView !== "original");
  const showingComparison = Boolean(currentArticleTranslation && articleTranslationView === "comparison");
  const structuredHtmlTranslation = useMemo(() => {
    if (!currentArticleTranslation || !structuredHtmlPlan) return null;
    const envelope = decodeStructuredTextTranslationResult(currentArticleTranslation.translatedText);
    if (!envelope) return null;
    try {
      return reconstructStructuredHtmlTranslation(structuredHtmlPlan, {
        translations: envelope.translations,
        detectedSourceLanguage: currentArticleTranslation.detectedSourceLanguage,
        provider: currentArticleTranslation.provider,
        model: currentArticleTranslation.model,
        targetLanguage: currentArticleTranslation.targetLanguage,
      });
    } catch {
      return null;
    }
  }, [currentArticleTranslation, structuredHtmlPlan]);
  const structuredEnvelopePresent = Boolean(currentArticleTranslation && currentArticleTranslation.translatedText.startsWith("repopress-structured-translation:v1:"));
  const structuredTranslation = useMemo(() => {
    if (!currentArticleTranslation || (structuredEnvelopePresent && !structuredHtmlTranslation)) return null;
    return buildStructuredTranslation(
      articleText,
      structuredHtmlTranslation?.translatedPlainText ?? currentArticleTranslation.translatedText,
      paragraphOverrides,
    );
  }, [articleText, currentArticleTranslation, paragraphOverrides, structuredEnvelopePresent, structuredHtmlTranslation]);

  const requestParagraphTranslation = useCallback((id: string, sourceText: string) => {
    if (!translationGateway) return;
    // This is deliberately separate from browser selection: it only supplies
    // the panel's selection scope and still requires plan confirmation.
    const request = { id, sourceText };
    programmaticParagraphRef.current = request;
    setProgrammaticParagraph(request);
    clearReadingSelection();
    translationActivationID.current += 1;
    setTranslationActivation({ id: translationActivationID.current, scope: "selection" });
  }, [clearReadingSelection, translationGateway]);

  const onTranslationResultChange = useCallback((change: RssTranslationResultChange) => {
    if (change.scope === "article") {
      const nextRequestKey = change.result ? change.requestKey : null;
      if (articleTranslationRequestKey.current !== nextRequestKey) {
        articleTranslationRequestKey.current = nextRequestKey;
        programmaticParagraphRef.current = null;
        setProgrammaticParagraph(null);
        setParagraphOverrides({});
      }
      return;
    }
    const pending = programmaticParagraphRef.current;
    if (change.scope !== "selection" || !pending || change.sourceText !== pending.sourceText) return;
    if (change.result) {
      setParagraphOverrides((current) => ({ ...current, [pending.id]: change.result!.translatedText }));
    } else {
      setParagraphOverrides((current) => {
        if (!Object.prototype.hasOwnProperty.call(current, pending.id)) return current;
        const { [pending.id]: _removed, ...rest } = current;
        return rest;
      });
    }
  }, []);

  const captureReadingSelection = useCallback(() => {
    programmaticParagraphRef.current = null;
    setProgrammaticParagraph(null);
    const text = window.getSelection()?.toString().trim() ?? "";
    setHighlightText(text);
    setSelectionText(text);
  }, []);

  if (!selectedId) return <section className="rss-article-reader rss-empty" aria-label={t("文章正文")}>{t("选择一篇文章开始阅读。")}</section>;
  if (loading) return <section className="rss-article-reader rss-empty" aria-label={t("文章正文")} role="status">{t("正在读取本机正文…")}</section>;
  if (!article) return <section className="rss-article-reader rss-empty" aria-label={t("文章正文")}>{t("暂时无法读取这篇文章的本机正文。")}</section>;

  const source = sourceHtml || `<p>${t("这篇文章没有可显示的正文。")}</p>`;
  const displayedTranslationHtml = structuredHtmlTranslation?.translatedHtml ?? "";
  const displayedTranslationTitle = structuredHtmlTranslation?.translatedTitle.trim() || article.title;
  const originalUrl = safeExternalHttpUrl(article.link);
  const articleStyle = {
    "--rss-font-size": `${style.fontSize}px`,
    "--rss-line-height": String(style.lineHeight),
    "--rss-paragraph-space": `${style.paragraphSpacing}em`,
    "--rss-text-align": style.alignment === "justify" ? "justify" : "start",
    "--rss-font-family": style.fontFamily === "system" ? "system-ui, sans-serif" : style.fontFamily === "songti" ? "Songti SC, STSong, serif" : "ui-serif, Georgia, serif",
  } as React.CSSProperties;
  const speak = (selectedText?: string) => {
    if (!("speechSynthesis" in window)) return;
    if (speech === "speaking") { window.speechSynthesis.pause(); setSpeech("paused"); return; }
    if (speech === "paused") { window.speechSynthesis.resume(); setSpeech("speaking"); return; }
    const currentSpeechGeneration = speechGeneration.current + 1;
    speechGeneration.current = currentSpeechGeneration;
    const utterance = new SpeechSynthesisUtterance(selectedText?.trim() || (showingComparison
      ? structuredTranslation ? structuredTranslationText(structuredTranslation) : ""
      : showingArticleTranslation ? structuredHtmlTranslation ? `${displayedTranslationTitle}。${structuredHtmlTranslation.translatedPlainText}` : currentArticleTranslation?.translatedText ?? "" : `${article.title}。${articleText || article.readableSummary}`));
    utterance.rate = rate;
    utterance.onend = () => { if (speechGeneration.current === currentSpeechGeneration) setSpeech("idle"); };
    utterance.onerror = () => { if (speechGeneration.current === currentSpeechGeneration) setSpeech("idle"); };
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(utterance);
    setSpeech("speaking");
  };
  const activateTranslation = (scope: "article" | "selection") => {
    if (!translationGateway) return;
    programmaticParagraphRef.current = null;
    setProgrammaticParagraph(null);
    translationActivationID.current += 1;
    setTranslationActivation({ id: translationActivationID.current, scope });
  };
  return <section className={`rss-article-reader theme-${style.theme} code-theme-${style.codeTheme}`} aria-label={t("文章正文")} style={articleStyle}>
    <header>
      <p>{feed?.title ?? "RSS"} · {formatDate(article.publishedAt ?? article.fetchedAt, locale)} · {t("阅读进度 {percent}%", { percent: formatNumber(Math.round(progress * 100), locale) })}</p>
      <h2>{showingArticleTranslation && structuredHtmlTranslation ? displayedTranslationTitle : article.title}</h2>
      <div className="rss-reader-actions">
        <button type="button" onClick={onToggleRead}>{t(article.readAt ? "标为未读" : "标为已读")}</button>
        <button type="button" onClick={onToggleStar}>{t(article.isStarred ? "取消稍后阅读" : "加入稍后阅读")}</button>
        <button type="button" onClick={() => fullTextReady ? onShowFullText() : onFetchFullText(false)} disabled={fullTextBusy}>{t(fullTextBusy ? "提取中…" : fullTextReady ? showFullText ? "显示 Feed 正文" : "显示全文" : "提取全文")}</button>
        {fullText && fullText.status !== "ready" && <button type="button" onClick={() => onFetchFullText(true)}>{t("重试全文")}</button>}
        {translationGateway && <button type="button" className="rss-translation-trigger" onClick={() => activateTranslation("article")}>{t("翻译文章")}</button>}
        {currentArticleTranslation && <><button type="button" className="rss-article-translation-toggle" onClick={() => setTranslationView("original")} disabled={articleTranslationView === "original"}>{t("显示原文")}</button><button type="button" className="rss-article-translation-toggle" onClick={() => setTranslationView("translation")} disabled={articleTranslationView === "translation"}>{t("显示译文")}</button><button type="button" className="rss-article-translation-toggle" onClick={() => setTranslationView(showingComparison ? "translation" : "comparison")}>{t(showingComparison ? "退出对照" : "原译对照")}</button></>}
        <button type="button" onClick={() => speak()} disabled={!("speechSynthesis" in window)}>{t(speech === "speaking" ? "暂停朗读" : speech === "paused" ? "继续朗读" : "朗读")}</button>
        {speech !== "idle" && <button type="button" onClick={stopSpeech}>{t("停止")}</button>}
        {onSaveToKnowledge && <button type="button" onClick={onSaveToKnowledge}>{t("保存到资料库")}</button>}
        {onInsertReference && <button type="button" onClick={() => onInsertReference()}>{t("插入当前稿件")}</button>}
        {onCreateInspirationDraft && <button type="button" onClick={onCreateInspirationDraft}>{t("创建灵感草稿")}</button>}
        {originalUrl && <a href={originalUrl} target="_blank" rel="noreferrer">{t("打开原文 ↗")}</a>}
      </div>
      {showingArticleTranslation && <p className="rss-article-translation-notice" role="status">{t(showingComparison ? "正在显示原译对照，原文与译文均为只读文本。" : structuredHtmlTranslation ? "正在显示富结构译文（保留标题、列表、引用、代码块和链接），原文未修改。" : structuredEnvelopePresent ? "结构化译文无法安全重建，已回退显示原文。" : "正在显示旧版纯文本译文，原文未修改。")}</p>}
      <div className="rss-reading-controls">
        <label>{t("主题")}<select value={style.theme} onChange={(event) => onStyle({ ...style, theme: event.target.value as RssReadingStyle["theme"] })}><option value="system">{t("系统")}</option><option value="warm">{t("暖纸")}</option><option value="light">{t("纯白")}</option><option value="dark">{t("暗色")}</option></select></label>
        <label>{t("字体")}<select value={style.fontFamily} onChange={(event) => onStyle({ ...style, fontFamily: event.target.value as RssReadingStyle["fontFamily"] })}><option value="system">{t("系统无衬线")}</option><option value="serif">{t("西文衬线")}</option><option value="songti">{t("宋体")}</option></select></label>
        <label>{t("字号")}<input type="range" min="13" max="24" value={style.fontSize} onChange={(event) => onStyle({ ...style, fontSize: Number(event.target.value) })} /></label>
        <label>{t("行距")}<input type="range" min="1.35" max="2.1" step=".05" value={style.lineHeight} onChange={(event) => onStyle({ ...style, lineHeight: Number(event.target.value) })} /></label>
        <label>{t("段距")}<input type="range" min=".45" max="1.4" step=".05" value={style.paragraphSpacing} onChange={(event) => onStyle({ ...style, paragraphSpacing: Number(event.target.value) })} /></label>
        <label>{t("对齐")}<select value={style.alignment} onChange={(event) => onStyle({ ...style, alignment: event.target.value as RssReadingStyle["alignment"] })}><option value="natural">{t("自然")}</option><option value="justify">{t("两端")}</option></select></label>
        <label>{t("代码主题")}<select value={style.codeTheme} onChange={(event) => onStyle({ ...style, codeTheme: event.target.value as RssReadingStyle["codeTheme"] })}><option value="adaptive">{t("随阅读主题")}</option><option value="xcode">Xcode</option><option value="solarized">Solarized</option></select></label>
        <label>{t("朗读倍率")}<select value={rate} onChange={(event) => setRate(Number(event.target.value))}>{[1, 1.25, 1.5, 1.75, 2].map((value) => <option value={value} key={value}>{value}×</option>)}</select></label>
      </div>
      {fullText && fullText.status !== "ready" && <p className="rss-fulltext-error">{fullText.failureMessage ?? t("全文提取状态：{status}", { status: fullText.status })}{fullText.retryAfter ? t("；可于 {date} 后重试", { date: formatDate(fullText.retryAfter, locale) }) : ""}</p>}
    </header>
    {preferences.remoteImagesEnabled && coverDataUrl && <img className="rss-cover" src={coverDataUrl} alt="" />}
    {preferences.remoteImagesEnabled && article.coverUrl && coverBusy && <p className="rss-help" role="status">{t("正在安全加载封面…")}</p>}
    {preferences.remoteImagesEnabled && article.coverUrl && coverError && <p className="rss-help">{renderReaderMessage(coverError, t, locale)}</p>}
    {!preferences.remoteImagesEnabled && article.coverUrl && <p className="rss-help">{t("封面图片默认未加载；可在 RSS 偏好中开启远端图片。")}</p>}
    {showingComparison && structuredTranslation
      ? <div className="rss-article-body rss-article-comparison-body" onScroll={(event) => { const target = event.currentTarget; const denominator = target.scrollHeight - target.clientHeight; onProgress(denominator <= 0 ? 1 : target.scrollTop / denominator); }}>
        {!structuredTranslation.exactAlignment && <p className="rss-comparison-warning" role="status">{t("原文与译文段落数不一致：缺失译文不会补造；多余译文会单独列出。")}</p>}
        <div className="rss-comparison-grid" aria-label={t("原文与译文对照")}>
          {structuredTranslation.paragraphs.map((paragraph) => <article className="rss-comparison-pair" key={paragraph.id}>
            <section className="rss-comparison-source"><h3>{t("原文")}</h3><p>{paragraph.sourceText}</p>{translationGateway && <button type="button" onClick={() => requestParagraphTranslation(paragraph.id, paragraph.sourceText)}>{t("重译此段")}</button>}</section>
            <section className="rss-comparison-translation"><h3>{t("译文")}</h3>{paragraph.translatedText === null ? <p className="rss-comparison-missing">{t("本段暂无译文。")}</p> : <p>{paragraph.translatedText}</p>}</section>
          </article>)}
        </div>
        {structuredTranslation.unmatchedTranslations.length > 0 && <section className="rss-comparison-unmatched" aria-label={t("未匹配的多余译文")}><h3>{t("未匹配的多余译文")}</h3>{structuredTranslation.unmatchedTranslations.map((value, index) => <p key={`${index}-${value}`}>{value}</p>)}</section>}
      </div>
      : showingArticleTranslation
      ? structuredHtmlTranslation
        ? <div className="rss-article-body rss-article-translation-body rss-article-structured-translation" onMouseUp={captureReadingSelection} onScroll={(event) => { const target = event.currentTarget; const denominator = target.scrollHeight - target.clientHeight; onProgress(denominator <= 0 ? 1 : target.scrollTop / denominator); }}><div dangerouslySetInnerHTML={{ __html: sanitizeArticleHtml(displayedTranslationHtml) }} /></div>
        : structuredEnvelopePresent
          ? <div className="rss-article-body" onMouseUp={captureReadingSelection} onScroll={(event) => { const target = event.currentTarget; const denominator = target.scrollHeight - target.clientHeight; onProgress(denominator <= 0 ? 1 : target.scrollTop / denominator); }} dangerouslySetInnerHTML={{ __html: sanitizeArticleHtml(source) }} />
          : <div className="rss-article-body rss-article-translation-body" onMouseUp={captureReadingSelection} onScroll={(event) => { const target = event.currentTarget; const denominator = target.scrollHeight - target.clientHeight; onProgress(denominator <= 0 ? 1 : target.scrollTop / denominator); }}><div className="rss-article-translation-text">{currentArticleTranslation?.translatedText ?? ""}</div></div>
      : <div className="rss-article-body" onMouseUp={captureReadingSelection} onScroll={(event) => { const target = event.currentTarget; const denominator = target.scrollHeight - target.clientHeight; onProgress(denominator <= 0 ? 1 : target.scrollTop / denominator); }} dangerouslySetInnerHTML={{ __html: sanitizeArticleHtml(source) }} />}
    {selectionText && <aside className="rss-selection-bar" aria-label={t("所选正文操作")}><span>{t("已选 {count} 个字符", { count: formatNumber(selectionText.length, locale) })}</span><button type="button" onClick={() => onSaveHighlight(selectionText, note, tags.split(","))}>{t("保存高亮")}</button><button type="button" onClick={() => speak(selectionText)} disabled={!("speechSynthesis" in window)}>{t("朗读选中")}</button>{translationGateway && <button type="button" className="rss-translation-trigger" onClick={() => activateTranslation("selection")}>{t("翻译选中")}</button>}{onInsertReference && <button type="button" onClick={() => onInsertReference(selectionText)}>{t("插入当前稿件")}</button>}</aside>}
    <form className="rss-tag-editor" onSubmit={(event) => { event.preventDefault(); onTags(tags.split(",")); }}>
      <label>{t("标签")}<input value={tags} onChange={(event) => setTags(event.target.value)} placeholder={t("用逗号分隔")} /></label>
      <button type="submit">{t("保存标签")}</button>
    </form>
    <section className="rss-highlights">
      <h3>{t("高亮与笔记")}</h3>
      <textarea value={highlightText} onChange={(event) => setHighlightText(event.target.value)} placeholder={t("选中正文后会自动填入，也可手动输入摘录")} rows={2} />
      <input value={note} onChange={(event) => setNote(event.target.value)} placeholder={t("添加笔记（可选）")} />
      <button type="button" onClick={() => onSaveHighlight(highlightText, note, tags.split(","))} disabled={!highlightText.trim()}>{t("保存高亮")}</button>
      {highlights.map((item) => <article key={item.id}><blockquote>{item.text}</blockquote>{item.note && <p>{item.note}</p>}<small>{item.tags.join(" · ")}</small><button type="button" onClick={() => onDeleteHighlight(item.id)}>{t("删除")}</button></article>)}
    </section>
    <RssTranslationPanel articleId={article.id} feedId={feed?.id} feedTitle={feed?.title} articleTitle={article.title} articleHtml={sourceHtml} articleText={articleText} selectionText={programmaticParagraph?.sourceText ?? selectionText} activation={translationActivation} gateway={translationGateway} sessionCache={sessionCache} offlineTranslationGateway={rssGateway} offlineTranslationEnabled={preferences.offlineTranslationCacheEnabled} cacheRevision={cacheRevision} articleTranslationVisible={showingArticleTranslation} onArticleTranslationChange={onArticleTranslationChange} onTranslationResultChange={onTranslationResultChange} onToggleArticleTranslation={toggleArticleTranslation} />
  </section>;
}

function PreferenceControls({ preferences, onChange }: { preferences: RssPreferences; onChange: (value: RssPreferences) => void }) {
  const { locale, t } = useI18n(rssMessages);
  const toggle = <K extends keyof RssPreferences>(key: K) => (event: React.ChangeEvent<HTMLInputElement>) => onChange({ ...preferences, [key]: event.target.checked });
  const toggleOfflineTranslations = (event: React.ChangeEvent<HTMLInputElement>) => onChange({
    ...preferences,
    offlineTranslationCacheEnabled: event.target.checked,
    automaticLocalPretranslationOnRefreshEnabled: event.target.checked
      ? preferences.automaticLocalPretranslationOnRefreshEnabled
      : false,
  });
  return <>
    <label><input type="checkbox" checked={preferences.offlineTranslationCacheEnabled} onChange={toggleOfflineTranslations} /> {t("持久化整篇离线译文")}</label>
    <label>{t("译文保留天数")}<input type="number" min="1" max="3650" value={preferences.offlineTranslationRetentionDays} disabled={!preferences.offlineTranslationCacheEnabled} onChange={(event) => onChange({ ...preferences, offlineTranslationRetentionDays: Number(event.target.value) })} /></label>
    <label>{t("译文额度 MiB")}<input type="number" min="16" max="2048" value={preferences.offlineTranslationMaxMiB} disabled={!preferences.offlineTranslationCacheEnabled} onChange={(event) => onChange({ ...preferences, offlineTranslationMaxMiB: Number(event.target.value) })} /></label>
    <label><input type="checkbox" checked={preferences.automaticLocalPretranslationOnRefreshEnabled} disabled={!preferences.offlineTranslationCacheEnabled} onChange={toggle("automaticLocalPretranslationOnRefreshEnabled")} /> {t("刷新后仅为本机翻译服务生成预翻译计划（仍需确认）")}</label>
    <label><input type="checkbox" checked={preferences.feedBodyOfflineCacheEnabled} onChange={toggle("feedBodyOfflineCacheEnabled")} /> {t("保留 Feed 正文用于离线阅读")}</label>
    <label><input type="checkbox" checked={preferences.remoteImagesEnabled} onChange={toggle("remoteImagesEnabled")} /> {t("允许加载远端封面图片")}</label>
    <label><input type="checkbox" checked={preferences.automaticFullTextExtractionEnabled} onChange={toggle("automaticFullTextExtractionEnabled")} /> {t("打开文章时自动提取网页全文")}</label>
    <label><input type="checkbox" checked={preferences.offlineCacheFullTextOnRefreshEnabled} onChange={toggle("offlineCacheFullTextOnRefreshEnabled")} /> {t("刷新后预缓存网页全文（每次最多 32 篇）")}</label>
    <label><input type="checkbox" checked={preferences.automaticMarkReadAtEndEnabled} onChange={toggle("automaticMarkReadAtEndEnabled")} /> {t("阅读到末尾自动标为已读")}</label>
    <label><input type="checkbox" checked={preferences.backgroundRefreshEnabled} onChange={toggle("backgroundRefreshEnabled")} /> {t("工作区活跃时自动刷新")}</label>
    <label>{t("刷新间隔")}<select value={preferences.backgroundRefreshIntervalMinutes} onChange={(event) => onChange({ ...preferences, backgroundRefreshIntervalMinutes: Number(event.target.value) as RssPreferences["backgroundRefreshIntervalMinutes"] })}>{[15, 30, 60, 120].map((minutes) => <option value={minutes} key={minutes}>{t("{minutes} 分钟", { minutes: formatNumber(minutes, locale) })}</option>)}</select></label>
    <label><input type="checkbox" checked={preferences.privateNetworkAccessEnabled} onChange={toggle("privateNetworkAccessEnabled")} /> {t("允许访问本机或局域网订阅")}</label>
    <label><input type="checkbox" checked={preferences.automaticPruningEnabled} onChange={toggle("automaticPruningEnabled")} /> {t("自动清理过期已读文章")}</label>
    <label>{t("保留天数")}<input type="number" min="1" max="3650" value={preferences.retentionDays} onChange={(event) => onChange({ ...preferences, retentionDays: Number(event.target.value) })} /></label>
  </>;
}
function Modal({ title, children, onClose }: { title: string; children: React.ReactNode; onClose: () => void }) { const { t } = useI18n(rssMessages); return <div className="rss-modal-backdrop" role="presentation"><section className="rss-modal" role="dialog" aria-modal="true" aria-label={title}><header><h2>{title}</h2><button type="button" onClick={onClose} aria-label={t("关闭")}>×</button></header>{children}</section></div>; }
function translationResultKey(result: TextTranslationResult): string { return JSON.stringify([result.translatedText, result.detectedSourceLanguage, result.provider, result.model, result.targetLanguage]); }
function healthLabel(feed: RssFeed, t: UiTranslator) { return t(({ healthy: "健康", failing: "需要处理", backingOff: "等待重试", never: "尚未刷新" } as const)[feedHealth(feed)]); }
function localizedScopeLabel(scope: RssScope, feeds: RssFeed[], t: UiTranslator) { if (scope === "all") return t("全部文章"); if (scope === "unread") return t("未读"); if (scope === "starred") return t("稍后阅读"); return feeds.find((feed) => feed.id === scope.feed)?.title ?? t("订阅"); }
function formatDate(value: number, locale: string) { return new Date(value * 1000).toLocaleDateString(locale, { month: "short", day: "numeric" }); }
function formatNumber(value: number, locale: string) { return new Intl.NumberFormat(locale).format(value); }
function formatSizeMiB(value: number, locale: string) { return new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(value / 1024 / 1024); }
function localMessage(source: string, parameters?: UiMessage["parameters"]): ReaderMessage { return { kind: "local", message: { source, parameters } }; }
function rawMessage(text: string): ReaderMessage | null { return text ? { kind: "raw", text } : null; }
function renderReaderMessage(message: ReaderMessage, t: UiTranslator, locale: string) {
  if (message.kind === "raw") return message.text;
  const parameters = message.message.parameters && Object.fromEntries(Object.entries(message.message.parameters).map(([key, value]) => [key, typeof value === "number" ? formatNumber(value, locale) : value]));
  return renderUiMessage({ ...message.message, parameters }, t);
}
function messageFrom(error: unknown): ReaderMessage | null { if (error instanceof Error) return rawMessage(error.message); if (typeof error === "object" && error && "message" in error && typeof error.message === "string") return rawMessage(error.message); return localMessage("RSS 操作失败，请稍后重试。"); }
