import Foundation
import PublishingCoreSupport
import SQLite3

struct RSSHistoryCommitResult: Sendable {
  let progress: RSSHistoryBackfillProgress
  let header: RSSArticleHeader
}

extension RSSReaderDatabase {
  func historyBackfillProgress(feedID: UUID) throws -> RSSHistoryBackfillProgress? {
    try withLock { try historyBackfillProgressUnlocked(feedID: feedID) }
  }

  func saveHistoryBackfillProgress(_ progress: RSSHistoryBackfillProgress) throws {
    try withLock {
      try transactionUnlocked {
        try checkHistorySourceUnlocked(progress)
        // Optional history state is created only after an explicit backfill action.
        // Opening a reader database must not change its schema or article data.
        try executeUnlocked(
          """
          CREATE TABLE IF NOT EXISTS rss_history_jobs (
            feed_id TEXT PRIMARY KEY NOT NULL REFERENCES rss_feeds(id) ON DELETE CASCADE,
            checkpoint_json TEXT NOT NULL
          );
          """
        )
        try executeUnlocked(
          """
          CREATE TABLE IF NOT EXISTS rss_history_failures (
            feed_id TEXT NOT NULL REFERENCES rss_feeds(id) ON DELETE CASCADE,
            job_id TEXT NOT NULL, url_key TEXT NOT NULL, candidate_json TEXT NOT NULL,
            PRIMARY KEY(feed_id, url_key)
          );
          """
        )
        if progress.failureLedgerInitialized != true {
          for index in progress.failedIndices where progress.candidates.indices.contains(index) {
            try saveHistoryFailureUnlocked(progress.candidates[index], progress: progress)
          }
        }
        let discard = try prepareUnlocked(
          "DELETE FROM rss_history_failures WHERE feed_id = ? AND job_id != ?;")
        defer { sqlite3_finalize(discard) }
        bind(progress.feedID.uuidString, at: 1, to: discard)
        bind(progress.id.uuidString, at: 2, to: discard)
        guard sqlite3_step(discard) == SQLITE_DONE else { throw databaseErrorUnlocked() }
        var persisted = progress
        persisted.failureLedgerInitialized = true
        try saveHistoryBackfillProgressUnlocked(persisted)
      }
    }
  }

  /// Inserts new metadata only. Existing rows, including edited feed bodies,
  /// read/star/tag state and highlights, are never upserted by history work.
  func commitHistoryItem(
    progress: RSSHistoryBackfillProgress,
    proposedArticle: RSSArticle,
    verifiedAliases: Set<String>,
    record: RSSArticleFullTextRecord?
  ) throws -> RSSHistoryCommitResult {
    try withLock {
      var result: RSSHistoryCommitResult?
      try transactionUnlocked {
        try Task.checkCancellation()
        try checkHistorySourceUnlocked(progress)
        guard let saved = try historyBackfillProgressUnlocked(feedID: progress.feedID),
          saved.id == progress.id, saved.nextIndex == progress.nextIndex,
          progress.candidates.indices.contains(progress.nextIndex)
        else { throw RSSHistoryBackfillError.sourceChanged }
        let existing = try historyArticleUnlocked(feedID: progress.feedID, aliases: verifiedAliases)
        let article = existing ?? proposedArticle
        var updated = progress
        if existing == nil {
          // An ID conflict cannot silently replace an unrelated resource.
          guard try historyArticleIDIsAvailableUnlocked(article.id) else {
            throw RSSHistoryBackfillError.unavailable(CoreL10n.text("文章标识冲突，已保留原有记录。"))
          }
          try upsertArticleUnlocked(article)
          updated.addedCount += 1
        } else {
          updated.duplicateCount += 1
        }
        let previousIsReady = try historyHasReadyBodyUnlocked(article)
        if !previousIsReady, let record, record.status == .ready {
          let rebound = RSSArticleFullTextRecord(
            articleID: article.id, status: .ready,
            contentHTML: record.contentHTML, plainText: record.plainText,
            sourceURL: article.link, resolvedURL: record.resolvedURL,
            extractorIdentifier: record.extractorIdentifier,
            extractorVersion: record.extractorVersion,
            sourceETag: record.sourceETag, sourceLastModified: record.sourceLastModified,
            sourceContentHash: record.sourceContentHash, confidence: record.confidence,
            attemptedAt: record.attemptedAt
          )
          try upsertFullTextRecordUnlocked(rebound)
        }
        let bodyAvailable =
          previousIsReady || record?.status == .ready
          || (!article.contentHTML.isEmpty
            && !RSSArticleFullTextService().isTruncatedCandidate(article))
        if bodyAvailable {
          updated.fullTextSuccessCount += 1
          let clear = try prepareUnlocked(
            "DELETE FROM rss_history_failures WHERE feed_id = ? AND job_id = ? AND url_key = ?;")
          defer { sqlite3_finalize(clear) }
          bind(progress.feedID.uuidString, at: 1, to: clear)
          bind(progress.id.uuidString, at: 2, to: clear)
          bind(
            RSSHistoryURLIdentity.key(progress.candidates[progress.nextIndex].url), at: 3, to: clear
          )
          guard sqlite3_step(clear) == SQLITE_DONE else { throw databaseErrorUnlocked() }
        } else {
          updated.failedIndices.append(progress.nextIndex)
          try saveHistoryFailureUnlocked(
            progress.candidates[progress.nextIndex], progress: progress)
        }
        updated.fullTextFailureCount = try historyFailureCountUnlocked(progress)
        updated.nextIndex += 1
        try saveHistoryBackfillProgressUnlocked(updated)
        try Task.checkCancellation()
        result = RSSHistoryCommitResult(
          progress: updated, header: RSSArticleHeader(article: article))
      }
      guard let result else { throw RSSHistoryBackfillError.sourceChanged }
      return result
    }
  }

  func historyFailedCandidates(_ progress: RSSHistoryBackfillProgress) throws
    -> [RSSHistoryBackfillCandidate]
  {
    try withLock {
      guard
        try scalarIntUnlocked(
          "SELECT COUNT(*) FROM sqlite_master WHERE name = 'rss_history_failures';") > 0
      else {
        return progress.failedIndices.compactMap {
          progress.candidates.indices.contains($0) ? progress.candidates[$0] : nil
        }
      }
      let result = try historyFailedCandidatesUnlocked(
        progress, afterURLKey: progress.failureRetryAfterURLKey)
      if result.isEmpty, progress.failureRetryAfterURLKey != nil {
        return try historyFailedCandidatesUnlocked(progress, afterURLKey: nil)
      }
      return result
    }
  }

  private func historyFailedCandidatesUnlocked(
    _ progress: RSSHistoryBackfillProgress, afterURLKey: String?
  ) throws -> [RSSHistoryBackfillCandidate] {
    // Rotate bounded retry queues so a persistent failure cannot starve later URLs.
    let cursorClause = afterURLKey == nil ? "" : " AND url_key > ?"
    let statement = try prepareUnlocked(
      """
      SELECT candidate_json FROM rss_history_failures
      WHERE feed_id = ? AND job_id = ?\(cursorClause) ORDER BY url_key LIMIT 500;
      """)
    defer { sqlite3_finalize(statement) }
    bind(progress.feedID.uuidString, at: 1, to: statement)
    bind(progress.id.uuidString, at: 2, to: statement)
    if let afterURLKey { bind(afterURLKey, at: 3, to: statement) }
    var result: [RSSHistoryBackfillCandidate] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let data = text(statement, 0)?.data(using: .utf8), data.count <= 16 * 1_024 else {
        throw RSSReaderError.persistence(CoreL10n.text("历史补齐检查点无法读取。"))
      }
      result.append(try JSONDecoder().decode(RSSHistoryBackfillCandidate.self, from: data))
    }
    try checkStatementCompletion(statement)
    return result
  }

  private func saveHistoryFailureUnlocked(
    _ candidate: RSSHistoryBackfillCandidate, progress: RSSHistoryBackfillProgress
  ) throws {
    let data = try JSONEncoder().encode(candidate)
    guard data.count <= 16 * 1_024, let json = String(data: data, encoding: .utf8) else {
      throw RSSReaderError.persistence(CoreL10n.text("历史补齐检查点无法保存。"))
    }
    let statement = try prepareUnlocked(
      """
      INSERT INTO rss_history_failures(feed_id, job_id, url_key, candidate_json) VALUES (?, ?, ?, ?)
      ON CONFLICT(feed_id, url_key) DO UPDATE
      SET job_id = excluded.job_id, candidate_json = excluded.candidate_json;
      """)
    defer { sqlite3_finalize(statement) }
    bind(progress.feedID.uuidString, at: 1, to: statement)
    bind(progress.id.uuidString, at: 2, to: statement)
    bind(RSSHistoryURLIdentity.key(candidate.url), at: 3, to: statement)
    bind(json, at: 4, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
  }

  private func historyFailureCountUnlocked(_ progress: RSSHistoryBackfillProgress) throws -> Int {
    let statement = try prepareUnlocked(
      "SELECT COUNT(*) FROM rss_history_failures WHERE feed_id = ? AND job_id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(progress.feedID.uuidString, at: 1, to: statement)
    bind(progress.id.uuidString, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseErrorUnlocked() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func historyArticleUnlocked(feedID: UUID, aliases: Set<String>) throws -> RSSArticle? {
    let statement = try prepareUnlocked(
      """
      SELECT id, feed_id, title, link, cover_url, author, published_at, summary_html,
             content_html, web_page_snapshot_html, fetched_at, read_at, is_starred, tags_json
      FROM rss_articles WHERE feed_id = ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(feedID.uuidString, at: 1, to: statement)
    while sqlite3_step(statement) == SQLITE_ROW {
      if let link = text(statement, 3), let url = URL(string: link),
        aliases.contains(RSSHistoryURLIdentity.key(url))
      {
        return try decodeArticle(statement)
      }
    }
    try checkStatementCompletion(statement)
    return nil
  }

  private func historyArticleIDIsAvailableUnlocked(_ id: String) throws -> Bool {
    let statement = try prepareUnlocked("SELECT id FROM rss_articles WHERE id = ? LIMIT 1;")
    defer { sqlite3_finalize(statement) }
    bind(id, at: 1, to: statement)
    let code = sqlite3_step(statement)
    guard code == SQLITE_DONE || code == SQLITE_ROW else { throw databaseErrorUnlocked() }
    return code == SQLITE_DONE
  }

  private func historyHasReadyBodyUnlocked(_ article: RSSArticle) throws -> Bool {
    let statement = try prepareUnlocked(
      "SELECT status, source_url FROM rss_article_full_text WHERE article_id = ? LIMIT 1;"
    )
    defer { sqlite3_finalize(statement) }
    bind(article.id, at: 1, to: statement)
    let code = sqlite3_step(statement)
    guard code == SQLITE_DONE || code == SQLITE_ROW else { throw databaseErrorUnlocked() }
    return code == SQLITE_ROW && text(statement, 0) == "ready"
      && text(statement, 1) == article.link?.absoluteString
  }

  private func checkHistorySourceUnlocked(_ progress: RSSHistoryBackfillProgress) throws {
    let statement = try prepareUnlocked("SELECT url FROM rss_feeds WHERE id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(progress.feedID.uuidString, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW,
      text(statement, 0) == progress.feedURL.absoluteString
    else { throw RSSHistoryBackfillError.sourceChanged }
  }

  private func historyBackfillProgressUnlocked(feedID: UUID) throws -> RSSHistoryBackfillProgress? {
    guard
      try scalarIntUnlocked(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'rss_history_jobs';"
      ) > 0
    else { return nil }
    let statement = try prepareUnlocked(
      "SELECT checkpoint_json FROM rss_history_jobs WHERE feed_id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(feedID.uuidString, at: 1, to: statement)
    switch sqlite3_step(statement) {
    case SQLITE_DONE: return nil
    case SQLITE_ROW:
      guard let json = text(statement, 0), let data = json.data(using: .utf8),
        data.count <= 2 * 1_024 * 1_024
      else { throw RSSReaderError.persistence(CoreL10n.text("历史补齐检查点无法读取。")) }
      let progress = try JSONDecoder().decode(RSSHistoryBackfillProgress.self, from: data)
      guard progress.feedID == feedID, isValidHistoryCheckpoint(progress)
      else { throw RSSReaderError.persistence(CoreL10n.text("历史补齐检查点超出安全上限。")) }
      return progress
    default: throw databaseErrorUnlocked()
    }
  }

  private func isValidHistoryCheckpoint(_ progress: RSSHistoryBackfillProgress) -> Bool {
    progress.candidates.count <= 500
      && progress.visitedPages.count <= 10 && progress.pendingPages.count <= 10
      && progress.nextIndex >= 0 && progress.nextIndex <= progress.candidates.count
      && progress.discoveryCursor.map { (0...20_000).contains($0.articleOffset) } != false
      && (0...(Int.max - 500)).contains(progress.completedDiscoveryCount ?? 0)
      && progress.failedIndices.allSatisfy { progress.candidates.indices.contains($0) }
  }

  private func saveHistoryBackfillProgressUnlocked(_ progress: RSSHistoryBackfillProgress) throws {
    let data = try JSONEncoder().encode(progress)
    guard isValidHistoryCheckpoint(progress), data.count <= 2 * 1_024 * 1_024,
      let json = String(data: data, encoding: .utf8)
    else {
      throw RSSReaderError.persistence(CoreL10n.text("历史补齐检查点无法保存。"))
    }
    let statement = try prepareUnlocked(
      """
      INSERT INTO rss_history_jobs(feed_id, checkpoint_json) VALUES (?, ?)
      ON CONFLICT(feed_id) DO UPDATE SET checkpoint_json = excluded.checkpoint_json;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(progress.feedID.uuidString, at: 1, to: statement)
    bind(json, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
  }
}
