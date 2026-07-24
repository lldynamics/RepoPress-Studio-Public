import Foundation
import os

private let logger = Logger(subsystem: "com.repopress", category: "ContentMigrationService")

public enum ContentMigrationSourceKind: String, CaseIterable, Codable, Sendable {
  case wordpressWXR
  case rss
  case markdownFolder
  case genericJSON

  public var displayName: String {
    switch self {
    case .wordpressWXR: "WordPress WXR"
    case .rss: "RSS / Atom"
    case .markdownFolder: "Markdown 文件夹"
    case .genericJSON: "通用 JSON 导出"
    }
  }
}

public struct ContentMigrationImageMapping: Hashable, Sendable, Identifiable {
  public var id: String { sourcePath }
  public var sourcePath: String
  public var targetPath: String

  public init(sourcePath: String, targetPath: String) {
    self.sourcePath = sourcePath
    self.targetPath = targetPath
  }
}

public struct ContentMigrationRedirect: Hashable, Sendable, Identifiable {
  public var id: String { sourcePath }
  public var sourcePath: String
  public var targetPath: String

  public init(sourcePath: String, targetPath: String) {
    self.sourcePath = sourcePath
    self.targetPath = targetPath
  }
}

public struct ContentMigrationProfileConfiguration: Hashable, Sendable {
  public var profileID: UUID
  public var markdownPathPattern: String
  public var defaultAuthor: String

  public init(profile: SiteProfile) {
    self.profileID = profile.id
    self.markdownPathPattern = profile.markdownPathPattern.normalizedRelativePath()
    self.defaultAuthor = profile.defaultAuthor.trimmedForPublishing
  }
}

public enum ContentMigrationDraftDisposition: String, CaseIterable, Sendable {
  case insert
  case update
  case unchanged
  case conflict

  public var isSelectable: Bool {
    self == .insert || self == .update
  }
}

public struct ContentMigrationDraftBaseline: Hashable, Sendable {
  public var draft: ArticleDraft
  public var bodyRevision: UInt64

  public init(draft: ArticleDraft, bodyRevision: UInt64) {
    self.draft = draft
    self.bodyRevision = bodyRevision
  }
}

public struct ContentMigrationDraftReviewItem: Identifiable, Hashable, Sendable {
  public var id: UUID { importedDraft.id }
  public var importedDraft: ArticleDraft
  public var baseline: ContentMigrationDraftBaseline?
  public var disposition: ContentMigrationDraftDisposition
  public var comparison: DraftVersionComparison?

  public init(
    importedDraft: ArticleDraft,
    baseline: ContentMigrationDraftBaseline? = nil,
    disposition: ContentMigrationDraftDisposition,
    comparison: DraftVersionComparison? = nil
  ) {
    self.importedDraft = importedDraft
    self.baseline = baseline
    self.disposition = disposition
    self.comparison = comparison
  }

  public var repositoryPath: String {
    importedDraft.repositoryPath?.normalizedRelativePath() ?? ""
  }
}

public struct ContentMigrationPlan: Sendable {
  public var profileID: UUID
  public var profileConfiguration: ContentMigrationProfileConfiguration
  public var sourceKind: ContentMigrationSourceKind
  public var sourceName: String
  public var drafts: [ArticleDraft]
  public var imageMappings: [ContentMigrationImageMapping]
  public var redirects: [ContentMigrationRedirect]
  public var warnings: [String]
  public var reviewItems: [ContentMigrationDraftReviewItem]

  public init(
    profileID: UUID,
    profileConfiguration: ContentMigrationProfileConfiguration,
    sourceKind: ContentMigrationSourceKind,
    sourceName: String,
    drafts: [ArticleDraft],
    imageMappings: [ContentMigrationImageMapping],
    redirects: [ContentMigrationRedirect],
    warnings: [String],
    reviewItems: [ContentMigrationDraftReviewItem]? = nil
  ) {
    self.profileID = profileID
    self.profileConfiguration = profileConfiguration
    self.sourceKind = sourceKind
    self.sourceName = sourceName
    self.drafts = drafts
    self.imageMappings = imageMappings
    self.redirects = redirects
    self.warnings = warnings
    self.reviewItems = reviewItems ?? drafts.map {
      ContentMigrationDraftReviewItem(
        importedDraft: $0,
        disposition: .insert
      )
    }
  }

  public var redirectTableCSV: String {
    (["source,target"] + redirects.map { "\($0.sourcePath),\($0.targetPath)" }).joined(separator: "\n")
  }
}

public enum ContentMigrationError: LocalizedError {
  case unsupportedSource
  case unreadableSource(String)
  case invalidExport(String)
  case profileChanged
  case sourceOutsideSelectedDirectory(String)
  case sourceLimitExceeded(String)
  case draftsChanged([String])

  public var errorDescription: String? {
    switch self {
    case .unsupportedSource:
      return "请选择 WordPress WXR、RSS/Atom、JSON 导出文件或 Markdown 文件夹。"
    case let .unreadableSource(path):
      return "无法读取导入来源：\(path)"
    case let .invalidExport(message):
      return "无法识别导出内容：\(message)"
    case .profileChanged:
      return "迁移计划属于另一个站点配置，请重新生成预览后再导入。"
    case let .sourceOutsideSelectedDirectory(path):
      return "导入来源通过符号链接指向所选文件夹外部，已停止读取：\(path)"
    case let .sourceLimitExceeded(message):
      return message
    case let .draftsChanged(paths):
      let visiblePaths = paths.prefix(3).joined(separator: "、")
      let suffix = paths.count > 3 ? "等 \(paths.count) 篇" : ""
      return "生成预览后本地草稿已变化：\(visiblePaths)\(suffix)。请重新生成预览。"
    }
  }
}

public struct ContentMigrationLimits: Sendable {
  public var maximumSourceFileBytes: Int
  public var maximumRecordCount: Int
  public var maximumMarkdownFileCount: Int
  public var maximumMarkdownFileBytes: Int
  public var maximumMarkdownFolderBytes: Int

  public init(
    maximumSourceFileBytes: Int = 100 * 1_024 * 1_024,
    maximumRecordCount: Int = 10_000,
    maximumMarkdownFileCount: Int = 10_000,
    maximumMarkdownFileBytes: Int = 20 * 1_024 * 1_024,
    maximumMarkdownFolderBytes: Int = 100 * 1_024 * 1_024
  ) {
    self.maximumSourceFileBytes = max(1, maximumSourceFileBytes)
    self.maximumRecordCount = max(1, maximumRecordCount)
    self.maximumMarkdownFileCount = max(1, maximumMarkdownFileCount)
    self.maximumMarkdownFileBytes = max(1, maximumMarkdownFileBytes)
    self.maximumMarkdownFolderBytes = max(1, maximumMarkdownFolderBytes)
  }

  public static let `default` = ContentMigrationLimits()
}

public struct ContentMigrationService: Sendable {
  private let fileSystem: SendableFileManager
  private let limits: ContentMigrationLimits

  private var fileManager: FileManager { fileSystem.value }

  public init(
    fileManager: FileManager = .default,
    limits: ContentMigrationLimits = .default
  ) {
    self.fileSystem = SendableFileManager(fileManager)
    self.limits = limits
  }

  public func makePlanAsync(sourceURL: URL, profile: SiteProfile) async throws -> ContentMigrationPlan {
    let service = self
    let task = Task.detached(priority: .userInitiated) { () throws -> ContentMigrationPlan in
      try Task.checkCancellation()
      return try service.makePlan(sourceURL: sourceURL, profile: profile)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func makePlan(sourceURL: URL, profile: SiteProfile) throws -> ContentMigrationPlan {
    try Task.checkCancellation()
    let records: [ContentMigrationRecord]
    let kind: ContentMigrationSourceKind
    var warnings: [String] = []

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
      throw ContentMigrationError.unreadableSource(sourceURL.path)
    }
    if isDirectory.boolValue {
      kind = .markdownFolder
      records = try markdownRecords(in: sourceURL)
    } else {
      let sourceFileSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard sourceFileSize <= limits.maximumSourceFileBytes else {
        throw ContentMigrationError.sourceLimitExceeded("导出文件超过 100 MB，请拆分后分批导入。")
      }
      if ["md", "markdown", "mdx"].contains(sourceURL.pathExtension.lowercased()),
         sourceFileSize > limits.maximumMarkdownFileBytes {
        throw ContentMigrationError.sourceLimitExceeded("单个 Markdown 文件过大，请拆分文章后再导入。")
      }
      let data = try Data(contentsOf: sourceURL)
      try Task.checkCancellation()
      let text = String(data: data, encoding: .utf8) ?? ""
      if sourceURL.pathExtension.lowercased() == "json" {
        kind = .genericJSON
        records = try jsonRecords(data: data)
      } else if text.localizedCaseInsensitiveContains("<wp:wxr_version") {
        kind = .wordpressWXR
        records = try xmlRecords(data: data, sourceKind: .wordpressWXR)
      } else if text.localizedCaseInsensitiveContains("<rss") || text.localizedCaseInsensitiveContains("<feed") {
        kind = .rss
        records = try xmlRecords(data: data, sourceKind: .rss)
      } else if ["md", "markdown", "mdx"].contains(sourceURL.pathExtension.lowercased()) {
        kind = .markdownFolder
        records = [try markdownRecord(fileURL: sourceURL)]
      } else {
        throw ContentMigrationError.unsupportedSource
      }
    }

    var imageMappings: [ContentMigrationImageMapping] = []
    var mappingKeys = Set<String>()
    var redirects: [ContentMigrationRedirect] = []
    var redirectKeys = Set<String>()
    var drafts: [ArticleDraft] = []
    var slugs = Set<String>()

    for record in records where !record.title.trimmedForPublishing.isEmpty {
      try Task.checkCancellation()
      let baseSlug = record.slug?.nilIfEmpty ?? SlugService.slug(from: record.title)
      let slug = uniqueSlug(baseSlug, existing: &slugs)
      let transformed = transformImages(in: record.body)
      for mapping in transformed.mappings where mappingKeys.insert(mapping.sourcePath).inserted {
        imageMappings.append(mapping)
      }
      let date = record.date ?? Date()
      var draft = ArticleDraft(
        siteProfileID: profile.id,
        title: record.title,
        date: date,
        slug: slug,
        tags: record.tags,
        categories: record.categories,
        authors: record.authors.isEmpty ? profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? [] : record.authors,
        draft: record.isDraft,
        summary: record.summary,
        bodyMarkdown: transformed.body,
        status: record.isDraft ? .draft : .published,
        createdAt: date,
        updatedAt: record.updatedAt ?? date
      )
      draft.repositoryPath = profile.markdownPath(for: draft)
      drafts.append(draft)

      if let sourcePath = normalizedSourcePath(record.link), !sourcePath.isEmpty {
        let targetPath = "/\(slug)/"
        if sourcePath != targetPath, redirectKeys.insert(sourcePath).inserted {
          redirects.append(ContentMigrationRedirect(sourcePath: sourcePath, targetPath: targetPath))
        }
      }
    }

    if drafts.count != records.count {
      warnings.append("跳过了 \(records.count - drafts.count) 条缺少标题的记录。")
    }
    if imageMappings.contains(where: { $0.sourcePath.hasPrefix("http") }) {
      warnings.append("远程图片已改写为目标路径；请在发布前下载或复制对应图片文件。")
    }
    if redirects.isEmpty, !drafts.isEmpty {
      warnings.append("来源没有稳定链接字段，未生成重定向规则。")
    }

    return ContentMigrationPlan(
      profileID: profile.id,
      profileConfiguration: ContentMigrationProfileConfiguration(profile: profile),
      sourceKind: kind,
      sourceName: sourceURL.lastPathComponent,
      drafts: drafts.sorted { $0.date > $1.date },
      imageMappings: imageMappings.sorted { $0.sourcePath < $1.sourcePath },
      redirects: redirects.sorted { $0.sourcePath < $1.sourcePath },
      warnings: warnings
    )
  }

  private func markdownRecords(in directoryURL: URL) throws -> [ContentMigrationRecord] {
    let canonicalDirectoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
    guard let enumerator = fileManager.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      throw ContentMigrationError.unreadableSource(directoryURL.path)
    }
    var records: [ContentMigrationRecord] = []
    var totalByteCount = 0
    for case let fileURL as URL in enumerator where ["md", "markdown", "mdx"].contains(fileURL.pathExtension.lowercased()) {
      try Task.checkCancellation()
      guard let canonicalFileURL = canonicalDescendant(candidateURL: fileURL, rootURL: canonicalDirectoryURL) else {
        throw ContentMigrationError.sourceOutsideSelectedDirectory(fileURL.path)
      }
      let values = try canonicalFileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { continue }
      guard records.count < limits.maximumMarkdownFileCount else {
        throw ContentMigrationError.sourceLimitExceeded("Markdown 文件超过 10,000 个，请拆分文件夹后分批导入。")
      }
      let fileByteCount = values.fileSize ?? 0
      guard fileByteCount <= limits.maximumMarkdownFileBytes else {
        throw ContentMigrationError.sourceLimitExceeded("单个 Markdown 文件过大：\(canonicalFileURL.lastPathComponent)。请拆分文章后再导入。")
      }
      let (nextTotal, overflow) = totalByteCount.addingReportingOverflow(fileByteCount)
      guard !overflow, nextTotal <= limits.maximumMarkdownFolderBytes else {
        throw ContentMigrationError.sourceLimitExceeded("Markdown 文件夹总体积过大，请拆分文件夹后分批导入。")
      }
      totalByteCount = nextTotal
      records.append(try markdownRecord(fileURL: canonicalFileURL))
    }
    return records
  }

  private func canonicalDescendant(candidateURL: URL, rootURL: URL) -> URL? {
    let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let canonicalCandidate = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
    guard canonicalCandidate.path.hasPrefix(rootPath) else {
      return nil
    }
    return canonicalCandidate
  }

  private func markdownRecord(fileURL: URL) throws -> ContentMigrationRecord {
    let text: String
    do {
      text = try String(contentsOf: fileURL, encoding: .utf8)
    } catch {
      logger.warning("无法读取文件 \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      throw ContentMigrationError.unreadableSource(fileURL.path)
    }
    let parsed = parseFrontMatter(text)
    let values = parsed.values
    let title = values["title"] ?? humanizedTitle(fileURL.deletingPathExtension().lastPathComponent)
    let date = parseMigrationDate(values["date"])
    return ContentMigrationRecord(
      title: title,
      slug: values["slug"],
      link: values["permalink"] ?? values["url"],
      body: parsed.body,
      summary: values["description"] ?? values["summary"] ?? values["excerpt"] ?? "",
      date: date,
      updatedAt: date,
      tags: list(values["tags"] ?? values["tag"]),
      categories: list(values["categories"] ?? values["category"]),
      authors: list(values["authors"] ?? values["author"]),
      isDraft: parseBool(values["draft"]) ?? false
    )
  }

  private func jsonRecords(data: Data) throws -> [ContentMigrationRecord] {
    let root = try JSONSerialization.jsonObject(with: data)
    let values: [[String: Any]]
    if let array = root as? [[String: Any]] {
      values = array
    } else if let object = root as? [String: Any] {
      values = (["posts", "items", "entries", "articles"] as [String]).compactMap { object[$0] as? [[String: Any]] }.first ?? []
    } else {
      values = []
    }
    guard !values.isEmpty else { throw ContentMigrationError.invalidExport("未找到 posts/items/entries/articles 数组") }
    guard values.count <= limits.maximumRecordCount else {
      throw ContentMigrationError.sourceLimitExceeded("导出记录超过 10,000 条，请拆分后分批导入。")
    }
    return values.map { object in
      let title = string(object, keys: ["title", "name"]) ?? ""
      return ContentMigrationRecord(
        title: title,
        slug: string(object, keys: ["slug", "post_name"]),
        link: string(object, keys: ["url", "link", "permalink"]),
        body: string(object, keys: ["content", "body", "html", "markdown", "content_html"]) ?? "",
        summary: string(object, keys: ["excerpt", "summary", "description"]) ?? "",
        date: parseMigrationDate(string(object, keys: ["date", "published_at", "published"])) ,
        updatedAt: parseMigrationDate(string(object, keys: ["updated_at", "modified", "updated"])),
        tags: stringList(object, keys: ["tags", "tag"]),
        categories: stringList(object, keys: ["categories", "category"]),
        authors: stringList(object, keys: ["authors", "author"]),
        isDraft: bool(object, keys: ["draft", "is_draft"]) ?? false
      )
    }
  }

  private func xmlRecords(data: Data, sourceKind: ContentMigrationSourceKind) throws -> [ContentMigrationRecord] {
    let collector = XMLItemCollector(
      sourceKind: sourceKind,
      maximumRecordCount: limits.maximumRecordCount
    )
    let parser = XMLParser(data: data)
    parser.delegate = collector
    let didParse = parser.parse()
    if collector.wasCancelled {
      throw CancellationError()
    }
    if collector.didExceedRecordLimit {
      throw ContentMigrationError.sourceLimitExceeded("导出记录超过 10,000 条，请拆分后分批导入。")
    }
    guard didParse else {
      throw ContentMigrationError.invalidExport(parser.parserError?.localizedDescription ?? "XML 解析失败")
    }
    return collector.records
  }

  private func transformImages(in body: String) -> (body: String, mappings: [ContentMigrationImageMapping]) {
    var mappings: [ContentMigrationImageMapping] = []
    let body = htmlImagesAsMarkdown(body)
    let imagePattern = try? NSRegularExpression(pattern: MarkdownPatterns.imagePattern)
    let range = NSRange(body.startIndex..., in: body)
    var rewritten = body
    let matches = imagePattern?.matches(in: body, range: range) ?? []
    for match in matches.reversed() {
      guard
            let pathRange = Range(match.range(at: 2), in: body),
            let fullRange = Range(match.range, in: body) else { continue }
      let source = String(body[pathRange])
      let target = migrationImagePath(source)
      mappings.append(ContentMigrationImageMapping(sourcePath: source, targetPath: target))
      let altRange = Range(match.range(at: 1), in: body)
      let alt = altRange.map { String(body[$0]) } ?? ""
      rewritten.replaceSubrange(fullRange, with: "![\(alt)](\(target))")
    }
    return (htmlToMarkdown(rewritten), mappings)
  }

  private func htmlImagesAsMarkdown(_ body: String) -> String {
    guard let pattern = try? NSRegularExpression(pattern: #"<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#, options: [.caseInsensitive]) else {
      return body
    }
    let range = NSRange(body.startIndex..., in: body)
    var rewritten = body
    for match in pattern.matches(in: body, range: range).reversed() {
      guard
            let fullRange = Range(match.range, in: body),
            let pathRange = Range(match.range(at: 1), in: body) else { continue }
      rewritten.replaceSubrange(fullRange, with: "![](\(body[pathRange]))")
    }
    return rewritten
  }

  private func migrationImagePath(_ source: String) -> String {
    let remoteURL = URL(string: source).flatMap { $0.scheme == nil ? nil : $0 }
    let rawPath = remoteURL?.path ?? source.components(separatedBy: "?").first ?? source
    var components = rawPath
      .split(separator: "/")
      .map(String.init)
      .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
      .map { $0.replacingOccurrences(of: "..", with: "") }
    if let host = remoteURL?.host?.nilIfEmpty {
      components.insert(host, at: 0)
    }
    if components.isEmpty { components = ["image"] }
    return "/assets/imported/\(components.joined(separator: "/"))"
  }

  private func htmlToMarkdown(_ value: String) -> String {
    value
      .replacingOccurrences(of: "<br>", with: "\n")
      .replacingOccurrences(of: "<br/>", with: "\n")
      .replacingOccurrences(of: "</p>", with: "\n\n")
      .replacingOccurrences(of: "</div>", with: "\n\n")
      .replacingOccurrences(of: "<li>", with: "- ")
      .replacingOccurrences(of: "</li>", with: "\n")
      .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func parseFrontMatter(_ document: String) -> (values: [String: String], body: String) {
    guard let parsed = DelimitedFrontMatterParser().split(document) else {
      return ([:], document)
    }
    var values: [String: String] = [:]
    for line in parsed.contentLines {
      let separator: Character = parsed.delimiter == .toml ? "=" : ":"
      let parts = line.split(separator: separator, maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      values[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'"))
    }
    return (values, parsed.body)
  }

  private func normalizedSourcePath(_ link: String?) -> String? {
    guard let link = link?.trimmedForPublishing.nilIfEmpty else { return nil }
    if let url = URL(string: link), url.scheme != nil {
      let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return path.isEmpty ? "/" : "/\(path)/"
    }
    return link.hasPrefix("/") ? link : "/\(link)"
  }

  private func uniqueSlug(_ proposed: String, existing: inout Set<String>) -> String {
    let root = proposed.trimmedForPublishing.nilIfEmpty ?? "imported-post"
    var candidate = root
    var suffix = 2
    while !existing.insert(candidate).inserted {
      candidate = "\(root)-\(suffix)"
      suffix += 1
    }
    return candidate
  }

  private func list(_ value: String?) -> [String] {
    value?
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .split(separator: ",")
      .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'")) }
      .filter { !$0.isEmpty } ?? []
  }

  private func parseBool(_ value: String?) -> Bool? {
    switch value?.trimmedForPublishing.lowercased() {
    case "true", "yes", "1", "draft": true
    case "false", "no", "0", "publish", "published": false
    default: nil
    }
  }

  private func humanizedTitle(_ filename: String) -> String {
    filename.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
  }

  private func string(_ object: [String: Any], keys: [String]) -> String? {
    keys.compactMap { object[$0] as? String }.first?.nilIfEmpty
  }

  private func stringList(_ object: [String: Any], keys: [String]) -> [String] {
    for key in keys {
      if let values = object[key] as? [String] { return values }
      if let value = object[key] as? String { return list(value) }
    }
    return []
  }

  private func bool(_ object: [String: Any], keys: [String]) -> Bool? {
    for key in keys {
      if let value = object[key] as? Bool { return value }
      if let value = object[key] as? String, let parsed = parseBool(value) { return parsed }
    }
    return nil
  }

}

fileprivate struct ContentMigrationRecord {
  var title: String
  var slug: String?
  var link: String?
  var body: String
  var summary: String
  var date: Date?
  var updatedAt: Date?
  var tags: [String]
  var categories: [String]
  var authors: [String]
  var isDraft: Bool
}

fileprivate func parseMigrationDate(_ value: String?) -> Date? {
  guard let value = value?.trimmedForPublishing.nilIfEmpty else { return nil }
  if let date = ISO8601DateFormatter().date(from: value) { return date }
  let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "EEE, dd MMM yyyy HH:mm:ss Z"]
  for format in formats {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    if let date = formatter.date(from: value) { return date }
  }
  return nil
}

private final class XMLItemCollector: NSObject, XMLParserDelegate {
  private let sourceKind: ContentMigrationSourceKind
  private let maximumRecordCount: Int
  private var currentItem: [String: String] = [:]
  private var currentElement = ""
  private var text = ""
  private var categories: [String] = []
  private var tags: [String] = []
  var records: [ContentMigrationRecord] = []
  private(set) var didExceedRecordLimit = false
  private(set) var wasCancelled = false

  init(sourceKind: ContentMigrationSourceKind, maximumRecordCount: Int) {
    self.sourceKind = sourceKind
    self.maximumRecordCount = maximumRecordCount
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
    guard !Task.isCancelled else {
      wasCancelled = true
      parser.abortParsing()
      return
    }
    currentElement = qName ?? elementName
    text = ""
    if currentElement == "item" || currentElement == "entry" {
      currentItem = [:]
      categories = []
      tags = []
    }
    if currentElement == "link", let href = attributeDict["href"]?.nilIfEmpty {
      currentItem["link"] = href
    }
    if currentElement == "category", let domain = attributeDict["domain"]?.lowercased(), domain.contains("tag") {
      currentItem["category-domain"] = "tag"
    } else if currentElement == "category", let term = attributeDict["term"]?.nilIfEmpty {
      categories.append(term)
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    text += String(data: CDATABlock, encoding: .utf8) ?? ""
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    let element = qName ?? elementName
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if element == "category", !value.isEmpty {
      if currentItem["category-domain"] == "tag" { tags.append(value) } else { categories.append(value) }
      currentItem["category-domain"] = nil
    } else if !value.isEmpty {
      currentItem[element] = value
    }
    if element == "item" || element == "entry" {
      guard sourceKind != .wordpressWXR || currentItem["wp:post_type"] == "post" else {
        currentElement = ""
        text = ""
        return
      }
      let title = currentItem["title"] ?? ""
      guard records.count < maximumRecordCount else {
        didExceedRecordLimit = true
        parser.abortParsing()
        currentElement = ""
        text = ""
        return
      }
      let status = currentItem["wp:status"]?.lowercased()
      let body = currentItem["content:encoded"] ?? currentItem["content"] ?? currentItem["description"] ?? ""
      records.append(ContentMigrationRecord(
        title: title,
        slug: currentItem["wp:post_name"],
        link: currentItem["link"],
        body: body,
        summary: currentItem["excerpt:encoded"] ?? currentItem["summary"] ?? currentItem["description"] ?? "",
        date: parseMigrationDate(currentItem["wp:post_date"] ?? currentItem["pubDate"] ?? currentItem["published"] ?? currentItem["updated"]),
        updatedAt: parseMigrationDate(currentItem["wp:post_date_gmt"] ?? currentItem["updated"]),
        tags: tags,
        categories: categories,
        authors: [currentItem["dc:creator"] ?? currentItem["author"]].compactMap { $0?.nilIfEmpty },
        isDraft: status == "draft" || status == "private"
      ))
    }
    currentElement = ""
    text = ""
  }
}
