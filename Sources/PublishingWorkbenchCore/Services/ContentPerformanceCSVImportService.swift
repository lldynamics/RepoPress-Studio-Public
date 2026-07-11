import Foundation

public struct ContentPerformanceCSVImportReport: Sendable {
  public var importedSnapshots: [ContentPerformanceSnapshot]
  public var skippedRowCount: Int
  public var unmatchedRows: [String]
  public var sourceName: String

  public init(
    importedSnapshots: [ContentPerformanceSnapshot],
    skippedRowCount: Int,
    unmatchedRows: [String],
    sourceName: String
  ) {
    self.importedSnapshots = importedSnapshots
    self.skippedRowCount = skippedRowCount
    self.unmatchedRows = unmatchedRows
    self.sourceName = sourceName
  }

  public var statusMessage: String {
    var message = "\(sourceName)：已导入 \(importedSnapshots.count) 条内容表现快照"
    if skippedRowCount > 0 {
      message += "，跳过 \(skippedRowCount) 行"
    }
    if !unmatchedRows.isEmpty {
      message += "，有 \(unmatchedRows.count) 行未匹配到现有文章"
    }
    return message + "。"
  }
}

public struct ContentPerformanceCSVImportService: Sendable {
  private static let maximumFileBytes = 100 * 1_024 * 1_024

  public init() {}

  public func importFile(
    at sourceURL: URL,
    profile: SiteProfile,
    drafts: [ArticleDraft],
    sourceName: String = "CSV 导入"
  ) async throws -> ContentPerformanceCSVImportReport {
    try await Task.detached(priority: .userInitiated) {
      let fileSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard fileSize <= Self.maximumFileBytes else {
        throw ContentPerformanceCSVImportError.fileTooLarge
      }
      let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
      return try ContentPerformanceCSVImportService().import(
        data: data,
        profile: profile,
        drafts: drafts,
        sourceName: sourceName
      )
    }.value
  }

  public func `import`(
    data: Data,
    profile: SiteProfile,
    drafts: [ArticleDraft],
    sourceName: String = "CSV 导入"
  ) throws -> ContentPerformanceCSVImportReport {
    guard let content = String(data: data, encoding: .utf8) else {
      throw ContentPerformanceCSVImportError.unsupportedEncoding
    }

    let rows = parseCSV(content)
    guard let header = rows.first, !header.isEmpty else {
      throw ContentPerformanceCSVImportError.missingHeader
    }
    let indices = Dictionary(uniqueKeysWithValues: header.enumerated().map { (normalizedHeader($0.element), $0.offset) })
    guard let pageViewsIndex = firstIndex(in: indices, names: ["pageviews", "pageview", "views", "阅读量", "浏览量"]),
          let visitorsIndex = firstIndex(in: indices, names: ["visitors", "visitor", "users", "访客", "访客数", "用户"]) else {
      throw ContentPerformanceCSVImportError.missingMetrics
    }

    let pathIndex = firstIndex(in: indices, names: ["markdownpath", "path", "pathname", "url", "页面路径", "文章路径"])
    let titleIndex = firstIndex(in: indices, names: ["title", "pagetitle", "文章标题", "标题"])
    let capturedAtIndex = firstIndex(in: indices, names: ["date", "capturedat", "日期", "采集时间"])
    let draftsByPath = Dictionary(
      drafts.map { (profile.markdownPath(for: $0).normalizedRelativePath(), $0) },
      uniquingKeysWith: { _, later in later }
    )
    let draftsByTitle = Dictionary(grouping: drafts) { $0.title.trimmedForPublishing.lowercased() }
    var snapshots: [ContentPerformanceSnapshot] = []
    var skippedRowCount = 0
    var unmatchedRows: [String] = []

    for row in rows.dropFirst() where row.contains(where: { !$0.trimmedForPublishing.isEmpty }) {
      if Task.isCancelled {
        throw CancellationError()
      }
      guard let pageViews = integerValue(at: pageViewsIndex, in: row),
            let visitors = integerValue(at: visitorsIndex, in: row) else {
        skippedRowCount += 1
        continue
      }

      let rawPath = stringValue(at: pathIndex, in: row)
      let rawTitle = stringValue(at: titleIndex, in: row)
      let draft = draftForRow(
        rawPath: rawPath,
        rawTitle: rawTitle,
        draftsByPath: draftsByPath,
        draftsByTitle: draftsByTitle
      )
      guard let draft else {
        unmatchedRows.append(rawPath?.nilIfEmpty ?? rawTitle?.nilIfEmpty ?? "未命名行")
        continue
      }

      snapshots.append(ContentPerformanceSnapshot(
        profileID: profile.id,
        draftID: draft.id,
        title: draft.title,
        markdownPath: profile.markdownPath(for: draft),
        pageViews: pageViews,
        visitors: visitors,
        sourceName: sourceName,
        capturedAt: dateValue(at: capturedAtIndex, in: row) ?? Date()
      ))
    }

    return ContentPerformanceCSVImportReport(
      importedSnapshots: snapshots,
      skippedRowCount: skippedRowCount,
      unmatchedRows: unmatchedRows,
      sourceName: sourceName
    )
  }

  private func draftForRow(
    rawPath: String?,
    rawTitle: String?,
    draftsByPath: [String: ArticleDraft],
    draftsByTitle: [String: [ArticleDraft]]
  ) -> ArticleDraft? {
    if let rawPath {
      let normalizedPath = normalizedPath(rawPath)
      if let draft = draftsByPath[normalizedPath] { return draft }
    }
    if let rawTitle {
      return draftsByTitle[rawTitle.trimmedForPublishing.lowercased()]?.first
    }
    return nil
  }

  private func normalizedPath(_ value: String) -> String {
    let trimmed = value.trimmedForPublishing
    if let url = URL(string: trimmed), url.scheme != nil {
      return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).normalizedRelativePath()
    }
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")).normalizedRelativePath()
  }

  private func normalizedHeader(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
  }

  private func firstIndex(in indices: [String: Int], names: [String]) -> Int? {
    names.compactMap { indices[normalizedHeader($0)] }.first
  }

  private func stringValue(at index: Int?, in row: [String]) -> String? {
    guard let index, row.indices.contains(index) else { return nil }
    return row[index].trimmedForPublishing.nilIfEmpty
  }

  private func integerValue(at index: Int, in row: [String]) -> Int? {
    guard row.indices.contains(index) else { return nil }
    let normalized = row[index]
      .replacingOccurrences(of: ",", with: "")
      .trimmedForPublishing
    return Int(normalized)
  }

  private func dateValue(at index: Int?, in row: [String]) -> Date? {
    guard let value = stringValue(at: index, in: row) else { return nil }
    if let date = ISO8601DateFormatter().date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
  }

  private func parseCSV(_ content: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var isQuoted = false
    var index = content.startIndex

    while index < content.endIndex {
      let character = content[index]
      if character == "\"" {
        let nextIndex = content.index(after: index)
        if isQuoted, nextIndex < content.endIndex, content[nextIndex] == "\"" {
          field.append("\"")
          index = nextIndex
        } else {
          isQuoted.toggle()
        }
      } else if character == ",", !isQuoted {
        row.append(field)
        field = ""
      } else if (character == "\n" || character == "\r"), !isQuoted {
        if character == "\r" {
          let nextIndex = content.index(after: index)
          if nextIndex < content.endIndex, content[nextIndex] == "\n" {
            index = nextIndex
          }
        }
        row.append(field)
        rows.append(row)
        row = []
        field = ""
      } else {
        field.append(character)
      }
      index = content.index(after: index)
    }
    if !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows
  }
}

public enum ContentPerformanceCSVImportError: LocalizedError {
  case unsupportedEncoding
  case missingHeader
  case missingMetrics
  case profileChanged
  case fileTooLarge

  public var errorDescription: String? {
    switch self {
    case .unsupportedEncoding:
      return "CSV 必须是 UTF-8 编码。"
    case .missingHeader:
      return "CSV 缺少表头。"
    case .missingMetrics:
      return "CSV 需要 pageviews/views 和 visitors/users 两列。"
    case .profileChanged:
      return "导入期间站点配置已切换，请重新选择 CSV。"
    case .fileTooLarge:
      return "CSV 文件超过 100 MB，请拆分后分批导入。"
    }
  }
}
