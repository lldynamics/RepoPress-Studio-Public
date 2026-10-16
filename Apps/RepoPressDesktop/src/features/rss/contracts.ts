import type { PlanTextTranslationRequest, TextTranslationResult } from "../../contracts/repository";

export type RssScope = "all" | "unread" | "starred" | { feed: string };
export type RssSortOrder = "newest" | "oldest";
export type RssFeedHealth = "never" | "healthy" | "failing" | "backingOff";
export type RssIssueStage = "validation" | "discovery" | "transport" | "response" | "parsing" | "persistence";
export type RssRetryStrategy = "automatic" | "afterDate" | "manual" | "requiresAction" | "none";

export interface RssFeedIssue {
  stage: RssIssueStage;
  category: string;
  retryStrategy: RssRetryStrategy;
  retryAt: number | null;
  userMessage: string;
  technicalDetail: string | null;
  occurredAt: number;
}

export interface RssFeed {
  id: string;
  title: string;
  url: string;
  siteUrl: string | null;
  iconUrl: string | null;
  addedAt: number;
  lastUpdatedAt: number | null;
  etag: string | null;
  lastModified: string | null;
  lastError: string | null;
  lastIssue: RssFeedIssue | null;
  lastRefreshAttemptAt: number | null;
  refreshFailureCount: number;
  nextRetryAt: number | null;
  lastRefreshDuration: number | null;
}

export interface RssArticleHeader {
  id: string;
  feedId: string;
  title: string;
  link: string | null;
  coverUrl: string | null;
  author: string | null;
  publishedAt: number | null;
  readableSummary: string;
  fetchedAt: number;
  readAt: number | null;
  isStarred: boolean;
  tags: string[];
}

export interface RssArticle extends RssArticleHeader {
  summaryHtml: string;
  contentHtml: string;
  webPageSnapshotHtml: string | null;
}

export type RssFullTextStatus = "ready" | "rejected" | "failed";
export interface RssFullTextRecord {
  articleId: string;
  status: RssFullTextStatus;
  contentHtml: string;
  plainText: string;
  sourceUrl: string | null;
  resolvedUrl: string | null;
  extractorIdentifier: string;
  extractorVersion: string;
  sourceEtag: string | null;
  sourceLastModified: string | null;
  sourceContentHash: string | null;
  confidence: number;
  attemptedAt: number;
  retryAfter: number | null;
  failureMessage: string | null;
}

export interface RssHighlight {
  id: string;
  articleId: string;
  text: string;
  note: string;
  tags: string[];
  createdAt: number;
  updatedAt: number;
}

export interface RssReadingProgress { articleId: string; progress: number; revision: number; updatedAt: number; }
export interface RssBackupInspection { databaseSchemaVersion: number; feedCount: number; articleCount: number; highlightCount: number; indexedArticleCount: number; }
export interface RssRemoveFeedResult { undoToken: string | null; }
export interface RssMarkAllReadResult { changedCount: number; undoToken: string | null; }

export interface RssSnapshot {
  feeds: RssFeed[];
  articles: RssArticleHeader[];
  articleCount: number;
  unreadCount: number;
  starredCount: number;
  unreadCountByFeed: Record<string, number>;
  authors: string[];
  tags: string[];
  statusMessage: string | null;
  errorMessage: string | null;
}

export interface RssArticlePage {
  articles: RssArticleHeader[];
  totalCount: number;
  hasMore: boolean;
}

export interface RssPreferences {
  automaticPruningEnabled: boolean;
  retentionDays: number;
  feedBodyOfflineCacheEnabled: boolean;
  privateNetworkAccessEnabled: boolean;
  backgroundRefreshEnabled: boolean;
  backgroundRefreshIntervalMinutes: 15 | 30 | 60 | 120;
  automaticMarkReadAtEndEnabled: boolean;
  automaticFullTextExtractionEnabled: boolean;
  offlineCacheFullTextOnRefreshEnabled: boolean;
  remoteImagesEnabled: boolean;
  offlineTranslationCacheEnabled: boolean;
  offlineTranslationRetentionDays: number;
  offlineTranslationMaxMiB: number;
  automaticLocalPretranslationOnRefreshEnabled: boolean;
}

export interface RssOfflineTranslationRecord extends TextTranslationResult {
  articleId: string;
  createdAt: number;
  expiresAt: number;
  byteSize: number;
}
export interface RssOfflineTranslationCacheStatus {
  entryCount: number;
  totalBytes: number;
  maxBytes: number;
  expiredCount: number;
}
export interface RssOfflineTranslationCleanup {
  removedCount: number;
  freedBytes: number;
  remainingCount: number;
  remainingBytes: number;
}

export interface RssPruneSummary {
  removedArticleCount: number;
  removedMediaAssetCount: number;
  cutoffDate: number;
}

export type RssOpmlDirection = "import" | "export";
export type RssOpmlPrivacyAction = "redact" | "exclude";

export interface RssOpmlFinding {
  index: number;
  location: string;
  displayUrl: string;
  parameterNames: string[];
  containsUserInfo: boolean;
}

export interface RssOpmlReview {
  direction: RssOpmlDirection;
  fingerprint: string;
  totalCount: number;
  affectedCount: number;
  blockedCount: number;
  findings: RssOpmlFinding[];
}

export interface RssOpmlExecution {
  opml: string | null;
  importedCount: number;
  skippedCount: number;
  exportedCount: number;
  excludedCount: number;
}

export type RssHistoryJobStatus = "preview" | "paused" | "running" | "complete";
export type RssHistoryCandidateStatus = "pending" | "added" | "duplicate" | "updated" | "failed";

export interface RssHistoryCandidate {
  url: string;
  title: string;
  status: RssHistoryCandidateStatus;
  message: string | null;
  kind?: "article" | "fullText";
}

export interface RssHistoryJob {
  id: string;
  feedId: string;
  directoryUrl: string;
  status: RssHistoryJobStatus;
  candidates: RssHistoryCandidate[];
  addedCount: number;
  duplicateCount: number;
  updatedCount?: number;
  failedCount: number;
  discoveredCount?: number;
  hasMoreDiscovery?: boolean;
  fillExisting?: boolean;
  retryingFailures?: boolean;
  nextRequestAt: number;
  reachedLimit: boolean;
  message: string | null;
}

export interface RssHistoryCheckpointSummary {
  id: string;
  feedId: string;
  directoryUrl: string;
  status: RssHistoryJobStatus;
  candidateCount: number;
  pendingCount: number;
  addedCount: number;
  duplicateCount: number;
  updatedCount: number;
  failedCount: number;
  discoveredCount: number;
  hasMoreDiscovery: boolean;
  retryingFailures?: boolean;
  stale: boolean;
}

export interface RssRefreshSummary {
  successCount: number;
  failureCount: number;
  skippedCount: number;
  statusText?: string;
}

export interface RssGateway {
  snapshot(): Promise<RssSnapshot>;
  discover(homepageUrl: string): Promise<string[]>;
  addFeed(input: { url: string; title?: string | null; siteUrl?: string | null }): Promise<RssFeed>;
  updateFeedUrl(feedId: string, newUrl: string): Promise<RssFeed>;
  removeFeed(feedId: string): Promise<RssRemoveFeedResult | void>;
  /** Defaults to scheduled refresh; only an explicit manual action uses force=true. */
  refreshFeed(feedId: string, force?: boolean): Promise<RssRefreshSummary>;
  refreshAll(force?: boolean): Promise<RssRefreshSummary>;
  listArticles(input: { scope: RssScope; searchText: string; unreadOnly: boolean; author: string | null; tag: string | null; sort: RssSortOrder; offset: number; limit: number }): Promise<RssArticlePage>;
  getArticle(articleId: string): Promise<RssArticle | null>;
  updateArticleState(input: { articleId: string; readAt?: number | null; isStarred?: boolean; tags?: string[] }): Promise<RssArticleHeader>;
  markAllRead(input: { scope: RssScope; articleIds?: string[]; searchText?: string; unreadOnly?: boolean; author?: string | null; tag?: string | null }): Promise<RssMarkAllReadResult | number>;
  undoMarkAllRead(undoToken: string): Promise<void>;
  undoRemoveFeed(undoToken: string): Promise<void>;
  fetchFullText(articleId: string, force: boolean): Promise<RssFullTextRecord>;
  fetchCover(articleId: string): Promise<string | null>;
  listHighlights(articleId: string): Promise<RssHighlight[]>;
  saveHighlight(input: { id?: string | null; articleId: string; text: string; note: string; tags: string[] }): Promise<RssHighlight>;
  deleteHighlight(highlightId: string): Promise<void>;
  getReadingProgress(articleId: string): Promise<RssReadingProgress | null>;
  saveReadingProgress(input: { articleId: string; progress: number; revision: number }): Promise<RssReadingProgress>;
  importOpml(opml: string): Promise<{ importedCount: number; skippedCount: number }>;
  exportOpml(): Promise<string>;
  reviewOpml(input: { direction: RssOpmlDirection; opml?: string }): Promise<RssOpmlReview>;
  executeOpml(input: { direction: RssOpmlDirection; opml?: string; fingerprint: string; action: RssOpmlPrivacyAction }): Promise<RssOpmlExecution>;
  historyDiscover(input: { feedId: string; directoryUrl: string; maxPages: number; maxArticles: number; discoveryId: string; fillExisting?: boolean }): Promise<RssHistoryJob>;
  historyResumeDiscovery(input: { jobId: string; discoveryId: string; maxPages: number; maxArticles: number }): Promise<RssHistoryJob>;
  historyCancelDiscovery(discoveryId: string): Promise<void>;
  historyStatus(feedId: string): Promise<RssHistoryJob | null>;
  historyList(): Promise<RssHistoryCheckpointSummary[]>;
  historyClear(jobId: string): Promise<void>;
  historyPrepareRetry(input: { jobId: string; maxArticles: number }): Promise<RssHistoryJob>;
  historyStep(input: { jobId: string; retryFailures?: boolean }): Promise<RssHistoryJob>;
  historyPause(jobId: string): Promise<RssHistoryJob>;
  getPreferences(): Promise<RssPreferences>;
  updatePreferences(preferences: RssPreferences): Promise<RssPreferences>;
  prune(): Promise<RssPruneSummary>;
  exportBackup(): Promise<string>;
  inspectBackup(backupText: string): Promise<RssBackupInspection>;
  restoreBackup(backupText: string): Promise<RssBackupInspection>;
  getOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest }): Promise<RssOfflineTranslationRecord | null>;
  saveOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest; result: TextTranslationResult }): Promise<RssOfflineTranslationRecord>;
  deleteOfflineTranslation(input: { articleId: string; request: PlanTextTranslationRequest }): Promise<void>;
  offlineTranslationCacheStatus(): Promise<RssOfflineTranslationCacheStatus>;
  pruneOfflineTranslations(): Promise<RssOfflineTranslationCleanup>;
  clearOfflineTranslations(feedId?: string | null): Promise<RssOfflineTranslationCleanup>;
}
