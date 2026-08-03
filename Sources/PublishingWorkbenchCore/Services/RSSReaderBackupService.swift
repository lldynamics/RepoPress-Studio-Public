import Foundation
import SQLite3

public struct RSSReaderBackupInspection: Hashable, Sendable {
  public var databaseSchemaVersion: Int
  public var feedCount: Int
  public var articleCount: Int
  public var highlightCount: Int
  public var indexedArticleCount: Int

  public init(
    databaseSchemaVersion: Int,
    feedCount: Int,
    articleCount: Int,
    highlightCount: Int,
    indexedArticleCount: Int
  ) {
    self.databaseSchemaVersion = databaseSchemaVersion
    self.feedCount = feedCount
    self.articleCount = articleCount
    self.highlightCount = highlightCount
    self.indexedArticleCount = indexedArticleCount
  }
}

public enum RSSReaderBackupError: LocalizedError, Hashable, Sendable {
  case sourceUnavailable(String)
  case sourceAndDestinationMatch
  case unsupportedDatabaseVersion(found: Int, supported: Int)
  case databaseIntegrity(String)

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable(let detail):
      CoreL10n.format("RSS 备份来源不可用：%@", detail)
    case .sourceAndDestinationMatch:
      CoreL10n.text("RSS 备份目标不能覆盖正在读取的源数据库。")
    case .unsupportedDatabaseVersion(let found, let supported):
      CoreL10n.format(
        "RSS 数据库版本 %d 不受支持，当前版本仅支持 %d。",
        found,
        supported
      )
    case .databaseIntegrity(let detail):
      CoreL10n.format("RSS 备份数据库完整性校验失败：%@", detail)
    }
  }
}

/// Creates a portable, single-file snapshot of the RSS SQLite database.
///
/// The source may remain open in WAL mode. SQLite's online backup API reads a
/// consistent committed view, while the produced snapshot is switched back to
/// DELETE journal mode before validation and installation.
public final class RSSReaderBackupService: Sendable {
  public static let databaseFileName = "reader.sqlite"

  private static let requiredTableNames = [
    "rss_feeds",
    "rss_articles",
    "rss_article_highlights",
    "rss_articles_fts"
  ]
  private static let sidecarSuffixes = ["-wal", "-shm", "-journal"]
  private let fileManagerDependency: SendableFileManager

  private var fileManager: FileManager {
    fileManagerDependency.value
  }

  public init(fileManager: FileManager = .default) {
    self.fileManagerDependency = SendableFileManager(fileManager)
  }

  public func createBackup(
    from sourceDatabaseURL: URL,
    at destinationURL: URL
  ) throws -> RSSReaderBackupInspection {
    let sourceURL = sourceDatabaseURL.standardizedFileURL.resolvingSymlinksInPath()
    let destinationURL = destinationURL.standardizedFileURL
    guard sourceURL != destinationURL.resolvingSymlinksInPath() else {
      throw RSSReaderBackupError.sourceAndDestinationMatch
    }
    try validateSource(at: sourceURL)
    try ensureNoSidecars(at: destinationURL)
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      ".\(destinationURL.lastPathComponent).creating-\(UUID().uuidString)",
      isDirectory: false
    )
    removeIfPresent(at: temporaryURL)
    removeSidecars(at: temporaryURL)
    var shouldRemoveTemporary = true
    defer {
      if shouldRemoveTemporary { removeIfPresent(at: temporaryURL) }
      removeSidecars(at: temporaryURL)
    }

    let sourceHandle = try openDatabase(
      at: sourceURL,
      flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      fallbackMessage: CoreL10n.text("无法打开 RSS 源数据库")
    )
    defer { sqlite3_close(sourceHandle) }
    let destinationHandle = try openDatabase(
      at: temporaryURL,
      flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      fallbackMessage: CoreL10n.text("无法创建 RSS SQLite 快照")
    )

    let inspection: RSSReaderBackupInspection
    do {
      try copyDatabase(from: sourceHandle, to: destinationHandle)
      try execute("PRAGMA journal_mode = DELETE;", on: destinationHandle)
      try execute("PRAGMA synchronous = FULL;", on: destinationHandle)
      inspection = try inspectDatabase(destinationHandle)
    } catch {
      sqlite3_close(destinationHandle)
      throw error
    }
    guard sqlite3_close(destinationHandle) == SQLITE_OK else {
      throw RSSReaderBackupError.databaseIntegrity(
        CoreL10n.text("无法关闭 RSS 备份数据库")
      )
    }
    // A connection that opened the copied WAL header may leave empty WAL/SHM
    // artifacts behind even after `journal_mode = DELETE`. The handle is now
    // closed and the main file was fully validated, so these stale sidecars do
    // not contain committed data and can be removed before publication.
    removeSidecars(at: temporaryURL)
    try ensureNoSidecars(at: temporaryURL)

    try replaceItem(at: destinationURL, withItemAt: temporaryURL)
    shouldRemoveTemporary = false
    let installedInspection = try inspectBackup(at: destinationURL)
    guard installedInspection == inspection else {
      throw RSSReaderBackupError.databaseIntegrity(
        CoreL10n.text("安装后的数据统计与快照不一致")
      )
    }
    return installedInspection
  }

  public func inspectBackup(at backupURL: URL) throws -> RSSReaderBackupInspection {
    let backupURL = backupURL.standardizedFileURL
    try validateSource(at: backupURL)
    try ensureNoSidecars(at: backupURL)
    let handle = try openDatabase(
      at: backupURL,
      flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      fallbackMessage: CoreL10n.text("无法打开 RSS 备份数据库")
    )
    defer { sqlite3_close(handle) }
    return try inspectDatabase(handle)
  }

  private func validateSource(at fileURL: URL) throws {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw RSSReaderBackupError.sourceUnavailable(fileURL.path)
    }
    do {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw RSSReaderBackupError.sourceUnavailable(fileURL.path)
      }
    } catch let error as RSSReaderBackupError {
      throw error
    } catch {
      throw RSSReaderBackupError.sourceUnavailable(error.localizedDescription)
    }
  }

  private func copyDatabase(
    from sourceHandle: OpaquePointer,
    to destinationHandle: OpaquePointer
  ) throws {
    _ = sqlite3_busy_timeout(sourceHandle, 5_000)
    _ = sqlite3_busy_timeout(destinationHandle, 5_000)
    guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
      throw RSSReaderBackupError.databaseIntegrity(databaseMessage(destinationHandle))
    }

    var stepResult: Int32 = SQLITE_OK
    var retryCount = 0
    repeat {
      stepResult = sqlite3_backup_step(backup, -1)
      if stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
        retryCount += 1
        sqlite3_sleep(10)
      }
    } while (stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED) && retryCount < 500
    let finishResult = sqlite3_backup_finish(backup)
    guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
      throw RSSReaderBackupError.databaseIntegrity(databaseMessage(destinationHandle))
    }
  }

  private func inspectDatabase(_ handle: OpaquePointer) throws -> RSSReaderBackupInspection {
    let journalMode = try scalarText("PRAGMA journal_mode;", on: handle).lowercased()
    guard journalMode == "delete" else {
      throw RSSReaderBackupError.databaseIntegrity(
        CoreL10n.format("备份必须使用 DELETE journal，实际为 %@", journalMode)
      )
    }
    try validateQuickCheck(on: handle)
    try validateForeignKeys(on: handle)

    let databaseSchemaVersion = try scalarInt("PRAGMA user_version;", on: handle)
    guard databaseSchemaVersion == RSSReaderDatabase.currentSchemaVersion else {
      throw RSSReaderBackupError.unsupportedDatabaseVersion(
        found: databaseSchemaVersion,
        supported: RSSReaderDatabase.currentSchemaVersion
      )
    }
    let requiredTableList = Self.requiredTableNames
      .map { "'\($0)'" }
      .joined(separator: ", ")
    let requiredTableCount = try scalarInt(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN (\(requiredTableList));",
      on: handle
    )
    guard requiredTableCount == Self.requiredTableNames.count else {
      throw RSSReaderBackupError.databaseIntegrity(
        CoreL10n.text("备份缺少 RSS 必需数据表")
      )
    }

    let feedCount = try scalarInt("SELECT COUNT(*) FROM rss_feeds;", on: handle)
    let articleCount = try scalarInt("SELECT COUNT(*) FROM rss_articles;", on: handle)
    let highlightCount = try scalarInt("SELECT COUNT(*) FROM rss_article_highlights;", on: handle)
    let indexedArticleCount = try scalarInt("SELECT COUNT(*) FROM rss_articles_fts;", on: handle)
    let missingIndexCount = try scalarInt(
      """
      SELECT COUNT(*) FROM rss_articles AS article
      LEFT JOIN rss_articles_fts AS search ON search.article_id = article.id
      WHERE search.article_id IS NULL;
      """,
      on: handle
    )
    let orphanedIndexCount = try scalarInt(
      """
      SELECT COUNT(*) FROM rss_articles_fts AS search
      LEFT JOIN rss_articles AS article ON article.id = search.article_id
      WHERE article.id IS NULL;
      """,
      on: handle
    )
    guard indexedArticleCount == articleCount,
          missingIndexCount == 0,
          orphanedIndexCount == 0 else {
      throw RSSReaderBackupError.databaseIntegrity(
        CoreL10n.format(
          "RSS 文章数量 %d 与全文索引数量 %d 不一致",
          articleCount,
          indexedArticleCount
        )
      )
    }

    return RSSReaderBackupInspection(
      databaseSchemaVersion: databaseSchemaVersion,
      feedCount: feedCount,
      articleCount: articleCount,
      highlightCount: highlightCount,
      indexedArticleCount: indexedArticleCount
    )
  }

  private func validateQuickCheck(on handle: OpaquePointer) throws {
    let statement = try prepare("PRAGMA quick_check;", on: handle)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          columnText(statement, 0)?.lowercased() == "ok",
          sqlite3_step(statement) == SQLITE_DONE else {
      throw RSSReaderBackupError.databaseIntegrity(
        columnText(statement, 0) ?? CoreL10n.text("PRAGMA quick_check 未通过")
      )
    }
  }

  private func validateForeignKeys(on handle: OpaquePointer) throws {
    let statement = try prepare("PRAGMA foreign_key_check;", on: handle)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else {
      if result == SQLITE_ROW {
        let table = columnText(statement, 0) ?? CoreL10n.text("未知表")
        throw RSSReaderBackupError.databaseIntegrity(
          CoreL10n.format("外键约束无效：%@", table)
        )
      }
      throw RSSReaderBackupError.databaseIntegrity(databaseMessage(handle))
    }
  }

  private func openDatabase(
    at fileURL: URL,
    flags: Int32,
    fallbackMessage: String
  ) throws -> OpaquePointer {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK,
          let handle else {
      let message = handle.map(databaseMessage) ?? fallbackMessage
      if let handle { sqlite3_close(handle) }
      throw RSSReaderBackupError.databaseIntegrity(message)
    }
    return handle
  }

  private func execute(_ sql: String, on handle: OpaquePointer) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? databaseMessage(handle)
      sqlite3_free(errorMessage)
      throw RSSReaderBackupError.databaseIntegrity(message)
    }
  }

  private func scalarInt(_ sql: String, on handle: OpaquePointer) throws -> Int {
    let statement = try prepare(sql, on: handle)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw RSSReaderBackupError.databaseIntegrity(databaseMessage(handle))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func scalarText(_ sql: String, on handle: OpaquePointer) throws -> String {
    let statement = try prepare(sql, on: handle)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = columnText(statement, 0) else {
      throw RSSReaderBackupError.databaseIntegrity(databaseMessage(handle))
    }
    return value
  }

  private func prepare(_ sql: String, on handle: OpaquePointer) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RSSReaderBackupError.databaseIntegrity(databaseMessage(handle))
    }
    return statement
  }

  private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
  }

  private func databaseMessage(_ handle: OpaquePointer) -> String {
    String(cString: sqlite3_errmsg(handle))
  }

  private func ensureNoSidecars(at databaseURL: URL) throws {
    if let sidecar = sidecarURLs(for: databaseURL).first(where: {
      fileManager.fileExists(atPath: $0.path)
    }) {
      throw RSSReaderBackupError.databaseIntegrity(
        CoreL10n.format(
          "备份必须为单文件，但发现侧车文件 %@",
          sidecar.lastPathComponent
        )
      )
    }
  }

  private func removeSidecars(at databaseURL: URL) {
    for sidecarURL in sidecarURLs(for: databaseURL) {
      removeIfPresent(at: sidecarURL)
    }
  }

  private func removeIfPresent(at fileURL: URL) {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    do {
      try fileManager.removeItem(at: fileURL)
    } catch {
      // SQLite can unlink a transient journal between the existence check and
      // the removal. Cleanup is best effort; a remaining sidecar is rejected
      // by `ensureNoSidecars` before the snapshot is installed.
    }
  }

  private func sidecarURLs(for databaseURL: URL) -> [URL] {
    Self.sidecarSuffixes.map { suffix in
      URL(fileURLWithPath: databaseURL.path + suffix)
    }
  }

  private func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
    guard fileManager.fileExists(atPath: destinationURL.path) else {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
      return
    }

    let displacedURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      ".\(destinationURL.lastPathComponent).replaced-\(UUID().uuidString)",
      isDirectory: false
    )
    try fileManager.moveItem(at: destinationURL, to: displacedURL)
    do {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
      try? fileManager.removeItem(at: displacedURL)
    } catch let replacementError {
      if !fileManager.fileExists(atPath: destinationURL.path) {
        do {
          try fileManager.moveItem(at: displacedURL, to: destinationURL)
        } catch let rollbackError {
          throw RSSReaderBackupError.databaseIntegrity(
            CoreL10n.format(
              "替换 RSS 备份失败：%@；自动回滚失败：%@；旧备份保留在 %@",
              replacementError.localizedDescription,
              rollbackError.localizedDescription,
              displacedURL.lastPathComponent
            )
          )
        }
      }
      throw RSSReaderBackupError.databaseIntegrity(replacementError.localizedDescription)
    }
  }
}
