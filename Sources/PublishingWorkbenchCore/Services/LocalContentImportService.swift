import Foundation

public struct LocalContentImportResult: Codable, Hashable, Sendable {
  public var importedDrafts: [ArticleDraft]
  public var skippedPaths: [String]
  public var issues: [LocalContentImportIssue]

  public init(
    importedDrafts: [ArticleDraft],
    skippedPaths: [String],
    issues: [LocalContentImportIssue] = []
  ) {
    self.importedDrafts = importedDrafts
    self.skippedPaths = skippedPaths
    self.issues = issues
  }
}

public struct LocalContentImportIssue: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case invalidPath
    case inaccessibleFile
    case unreadableDocument
    case repositoryAccessUnavailable
  }

  public var path: String
  public var kind: Kind
  public var message: String

  public init(path: String, kind: Kind, message: String) {
    self.path = path
    self.kind = kind
    self.message = message
  }
}

public struct LocalContentImportMergeSummary: Codable, Hashable, Sendable {
  public var insertedCount: Int
  public var updatedCount: Int
  public var skippedCount: Int

  public init(insertedCount: Int, updatedCount: Int, skippedCount: Int) {
    self.insertedCount = insertedCount
    self.updatedCount = updatedCount
    self.skippedCount = skippedCount
  }

  public var changedCount: Int {
    insertedCount + updatedCount
  }
}

public struct LocalContentImportService: Sendable {
  static let maximumMarkdownDocumentByteCount = 16 * 1024 * 1024

  private let fileSystem: SendableFileManager
  private let contentIndexStore: LocalContentImportIndexStore?
  private let frontMatterParseObserver: (@Sendable () -> Void)?
  private let imageReferenceScanObserver: (@Sendable () -> Void)?

  private var fileManager: FileManager { fileSystem.value }

  public init(
    fileManager: FileManager = .default,
    contentIndexDirectoryURL: URL? = nil,
    isContentIndexEnabled: Bool = true
  ) {
    self.init(
      fileManager: fileManager,
      contentIndexDirectoryURL: contentIndexDirectoryURL,
      isContentIndexEnabled: isContentIndexEnabled,
      frontMatterParseObserver: nil,
      imageReferenceScanObserver: nil
    )
  }

  init(
    fileManager: FileManager,
    contentIndexDirectoryURL: URL?,
    isContentIndexEnabled: Bool,
    frontMatterParseObserver: (@Sendable () -> Void)?,
    imageReferenceScanObserver: (@Sendable () -> Void)?
  ) {
    self.fileSystem = SendableFileManager(fileManager)
    self.contentIndexStore = isContentIndexEnabled
      ? LocalContentImportIndexStore(
        fileManager: fileManager,
        directoryURL: contentIndexDirectoryURL
      )
      : nil
    self.frontMatterParseObserver = frontMatterParseObserver
    self.imageReferenceScanObserver = imageReferenceScanObserver
  }

  public func importDrafts(profile: SiteProfile) -> LocalContentImportResult {
    importDrafts(profile: profile, cancellationCheck: {})
  }

  public func importDrafts(
    profile: SiteProfile,
    repositoryPaths: [String]
  ) -> LocalContentImportResult {
    importDrafts(
      profile: profile,
      repositoryPaths: repositoryPaths,
      cancellationCheck: {}
    )
  }

  public func importDraftsAsync(profile: SiteProfile) async throws -> LocalContentImportResult {
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      try service.importDrafts(
        profile: profile,
        excludingRepositoryPaths: [],
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func importMissingDraftsAsync(
    profile: SiteProfile,
    excludingRepositoryPaths: Set<String>
  ) async throws -> LocalContentImportResult {
    let normalizedExcludedPaths = Set(
      excludingRepositoryPaths.map { $0.normalizedRelativePath() }
    )
    let service = self
    let task = Task.detached(priority: .utility) {
      try service.importDrafts(
        profile: profile,
        excludingRepositoryPaths: normalizedExcludedPaths,
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func importDraftsAsync(
    profile: SiteProfile,
    repositoryPaths: [String]
  ) async throws -> LocalContentImportResult {
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      try service.importDrafts(
        profile: profile,
        repositoryPaths: repositoryPaths,
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func importDraft(profile: SiteProfile, repositoryPath: String) -> LocalContentImportResult {
    guard let result = profile.withLocalRepositoryRootAccess({ rootURL in
      importDraft(rootURL: rootURL, repositoryPath: repositoryPath, profile: profile)
    }) else {
      return LocalContentImportResult(importedDrafts: [], skippedPaths: [repositoryPath])
    }

    return result
  }

  public func importDraft(
    document: String,
    repositoryPath: String,
    profile: SiteProfile,
    repositorySHA: String? = nil
  ) -> LocalContentImportResult {
    guard let result = profile.withLocalRepositoryRootAccess({ rootURL in
      importDraft(
        document: document,
        rootURL: rootURL,
        repositoryPath: repositoryPath,
        profile: profile,
        repositorySHA: repositorySHA
      )
    }) else {
      return LocalContentImportResult(importedDrafts: [], skippedPaths: [repositoryPath])
    }

    return result
  }

  func importDrafts(rootURL: URL, profile: SiteProfile) -> LocalContentImportResult {
    importDrafts(rootURL: rootURL, profile: profile, cancellationCheck: {})
  }

  private func importDrafts(
    profile: SiteProfile,
    excludingRepositoryPaths: Set<String> = [],
    cancellationCheck: () throws -> Void
  ) rethrows -> LocalContentImportResult {
    guard let result = try profile.withLocalRepositoryRootAccess({ rootURL in
      try importDrafts(
        rootURL: rootURL,
        profile: profile,
        excludingRepositoryPaths: excludingRepositoryPaths,
        cancellationCheck: cancellationCheck
      )
    }) else {
      return LocalContentImportResult(
        importedDrafts: [],
        skippedPaths: [],
        issues: [
          LocalContentImportIssue(
            path: profile.contentRoot,
            kind: .repositoryAccessUnavailable,
            message: "无法访问站点本地仓库。"
          )
        ]
      )
    }
    return result
  }

  private func importDrafts(
    rootURL: URL,
    profile: SiteProfile,
    excludingRepositoryPaths: Set<String> = [],
    cancellationCheck: () throws -> Void
  ) rethrows -> LocalContentImportResult {
    try cancellationCheck()
    var importedDrafts: [ArticleDraft] = []
    var skippedPaths: [String] = []
    var issues: [LocalContentImportIssue] = []
    let contentIndex = contentIndexStore?.snapshot(profile: profile, rootURL: rootURL)
    var refreshedIndexEntries: [String: LocalContentImportIndexEntry] = [:]

    var seenRoots = Set<String>()
    let importRoots = [profile.contentRoot, SiteProfile.privateContentRoot]
      .map { $0.normalizedRelativePath() }
      .filter { !$0.isEmpty && seenRoots.insert($0).inserted }

    for importRoot in importRoots {
      try cancellationCheck()
      let importRootURL = rootURL.appendingPathComponent(importRoot, isDirectory: true)
      guard let enumerator = fileManager.enumerator(
        at: importRootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else {
        continue
      }

      for case let fileURL as URL in enumerator {
        try cancellationCheck()
        guard ["md", "markdown", "mdx"].contains(fileURL.pathExtension.lowercased()) else {
          continue
        }

        guard let repositoryPath = repositoryRelativePath(rootURL: rootURL, fileURL: fileURL) else {
          skippedPaths.append(fileURL.path)
          issues.append(
            LocalContentImportIssue(
              path: fileURL.path,
              kind: .invalidPath,
              message: "文件无法转换为仓库内相对路径。"
            )
          )
          continue
        }

        guard !excludingRepositoryPaths.contains(repositoryPath.normalizedRelativePath()) else {
          if let cached = contentIndex?.entries[repositoryPath],
             cached.isCurrent(rootURL: rootURL, sourceURL: fileURL) {
            refreshedIndexEntries[repositoryPath] = cached
          }
          continue
        }

        guard canonicalRepositoryDescendant(candidateURL: fileURL, rootURL: rootURL) != nil,
              isRegularFile(at: fileURL) else {
          skippedPaths.append(repositoryPath)
          issues.append(
            LocalContentImportIssue(
              path: repositoryPath,
              kind: .inaccessibleFile,
              message: "文件不可访问、不是普通文件或超出仓库边界。"
            )
          )
          continue
        }

        if let cached = contentIndex?.entries[repositoryPath],
           cached.isCurrent(rootURL: rootURL, sourceURL: fileURL) {
          importedDrafts.append(cached.draft)
          refreshedIndexEntries[repositoryPath] = cached
          continue
        }

        let sourceMetadataBeforeRead = LocalContentImportFileMetadata.read(from: fileURL)
        do {
          let document = try BoundedFileReader.utf8String(
            relativePath: repositoryPath,
            under: rootURL,
            maximumByteCount: Self.maximumMarkdownDocumentByteCount
          )
          let parsedDocument = parseImportDocument(document)
          let importedDraft = draft(
            from: parsedDocument,
            rootURL: rootURL,
            fileURL: fileURL,
            repositoryPath: repositoryPath,
            profile: profile
          )
          importedDrafts.append(importedDraft)
          if isCacheableImportedDraft(importedDraft, parsedDocument: parsedDocument),
             let sourceMetadataBeforeRead,
             let entry = contentIndexStore?.entry(
            draft: importedDraft,
            sourceURL: fileURL,
            rootURL: rootURL,
            expectedSourceMetadata: sourceMetadataBeforeRead
          ) {
            refreshedIndexEntries[repositoryPath] = entry
          }
        } catch {
          skippedPaths.append(repositoryPath)
          issues.append(
            LocalContentImportIssue(
              path: repositoryPath,
              kind: .unreadableDocument,
              message: error.localizedDescription
            )
          )
        }
      }
    }

    if var contentIndex, contentIndex.entries != refreshedIndexEntries {
      contentIndex.entries = refreshedIndexEntries
      contentIndexStore?.save(contentIndex)
    }

    return LocalContentImportResult(
      importedDrafts: importedDrafts.sorted {
        if $0.date == $1.date {
          return ($0.repositoryPath ?? "").localizedCaseInsensitiveCompare($1.repositoryPath ?? "") == .orderedAscending
        }
        return $0.date > $1.date
      },
      skippedPaths: skippedPaths.sorted(),
      issues: issues.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    )
  }

  private func importDrafts(
    profile: SiteProfile,
    repositoryPaths: [String],
    cancellationCheck: () throws -> Void
  ) rethrows -> LocalContentImportResult {
    guard let result = try profile.withLocalRepositoryRootAccess({ rootURL in
      try importDrafts(
        rootURL: rootURL,
        repositoryPaths: repositoryPaths,
        profile: profile,
        cancellationCheck: cancellationCheck
      )
    }) else {
      return LocalContentImportResult(
        importedDrafts: [],
        skippedPaths: repositoryPaths,
        issues: repositoryPaths.map {
          LocalContentImportIssue(
            path: $0,
            kind: .repositoryAccessUnavailable,
            message: "无法访问站点本地仓库。"
          )
        }
      )
    }
    return result
  }

  func importDrafts(
    rootURL: URL,
    repositoryPaths: [String],
    profile: SiteProfile
  ) -> LocalContentImportResult {
    importDrafts(
      rootURL: rootURL,
      repositoryPaths: repositoryPaths,
      profile: profile,
      cancellationCheck: {}
    )
  }

  private func importDrafts(
    rootURL: URL,
    repositoryPaths: [String],
    profile: SiteProfile,
    cancellationCheck: () throws -> Void
  ) rethrows -> LocalContentImportResult {
    var importedDrafts: [ArticleDraft] = []
    var skippedPaths: [String] = []
    var issues: [LocalContentImportIssue] = []
    for path in repositoryPaths {
      try cancellationCheck()
      let result = importDraft(rootURL: rootURL, repositoryPath: path, profile: profile)
      importedDrafts.append(contentsOf: result.importedDrafts)
      skippedPaths.append(contentsOf: result.skippedPaths)
      issues.append(contentsOf: result.issues)
    }
    return LocalContentImportResult(
      importedDrafts: importedDrafts,
      skippedPaths: skippedPaths,
      issues: issues
    )
  }

  func importDraft(rootURL: URL, repositoryPath: String, profile: SiteProfile) -> LocalContentImportResult {
    guard let safePath = safeMarkdownRepositoryPath(repositoryPath, profile: profile) else {
      return LocalContentImportResult(
        importedDrafts: [],
        skippedPaths: [repositoryPath],
        issues: [
          LocalContentImportIssue(
            path: repositoryPath,
            kind: .invalidPath,
            message: "路径不是站点内容目录中的安全 Markdown 路径。"
          )
        ]
      )
    }

    let fileURL = rootURL.appendingPathComponent(safePath)
    guard canonicalRepositoryDescendant(candidateURL: fileURL, rootURL: rootURL) != nil,
          isRegularFile(at: fileURL) else {
      return LocalContentImportResult(
        importedDrafts: [],
        skippedPaths: [safePath],
        issues: [
          LocalContentImportIssue(
            path: safePath,
            kind: .inaccessibleFile,
            message: "文件不可访问、不是普通文件或超出仓库边界。"
          )
        ]
      )
    }

    do {
      let document = try BoundedFileReader.utf8String(
        relativePath: safePath,
        under: rootURL,
        maximumByteCount: Self.maximumMarkdownDocumentByteCount
      )
      return LocalContentImportResult(
        importedDrafts: [draft(from: document, rootURL: rootURL, fileURL: fileURL, repositoryPath: safePath, profile: profile)],
        skippedPaths: []
      )
    } catch {
      return LocalContentImportResult(
        importedDrafts: [],
        skippedPaths: [safePath],
        issues: [
          LocalContentImportIssue(
            path: safePath,
            kind: .unreadableDocument,
            message: error.localizedDescription
          )
        ]
      )
    }
  }

  func importDraft(
    document: String,
    rootURL: URL,
    repositoryPath: String,
    profile: SiteProfile,
    repositorySHA: String? = nil
  ) -> LocalContentImportResult {
    guard let safePath = safeMarkdownRepositoryPath(repositoryPath, profile: profile) else {
      return LocalContentImportResult(importedDrafts: [], skippedPaths: [repositoryPath])
    }

    let fileURL = rootURL.appendingPathComponent(safePath)
    return LocalContentImportResult(
      importedDrafts: [
        draft(
          from: document,
          rootURL: rootURL,
          fileURL: fileURL,
          repositoryPath: safePath,
          profile: profile,
          repositorySHA: repositorySHA
        )
      ],
      skippedPaths: []
    )
  }

  private func draft(
    from document: String,
    rootURL: URL,
    fileURL: URL,
    repositoryPath: String,
    profile: SiteProfile,
    repositorySHA: String? = nil
  ) -> ArticleDraft {
    draft(
      from: parseImportDocument(document),
      rootURL: rootURL,
      fileURL: fileURL,
      repositoryPath: repositoryPath,
      profile: profile,
      repositorySHA: repositorySHA
    )
  }

  private func draft(
    from parsedDocument: ParsedImportDocument,
    rootURL: URL,
    fileURL: URL,
    repositoryPath: String,
    profile: SiteProfile,
    repositorySHA: String? = nil
  ) -> ArticleDraft {
    let values = parsedDocument.values
    let fileModificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    let date = parsedDate(values["date"]?.first, profile: profile) ?? dateFromPath(repositoryPath) ?? fileModificationDate
    let title = values["title"]?.first?.nilIfEmpty ?? humanizedTitle(from: repositoryPath)
    let slug = values["slug"]?.first?.nilIfEmpty ?? slugFromPath(repositoryPath) ?? SlugService.slug(from: title)
    let summary = values["description"]?.first?.nilIfEmpty
      ?? values["summary"]?.first?.nilIfEmpty
      ?? values["excerpt"]?.first?.nilIfEmpty
      ?? ""
    let draftFlag = parsedBool(values["draft"]?.first) ?? false
    let visibility = importedVisibility(values: values, repositoryPath: repositoryPath, profile: profile)
    let authors = values["authors"] ?? values["author"] ?? profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? []
    let attachments = importedAttachments(
      values: values,
      imageReferences: parsedDocument.imageReferences,
      rootURL: rootURL,
      articleRepositoryPath: repositoryPath,
      profile: profile
    )

    var importedDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: title,
      date: date,
      slug: slug,
      tags: values["tags"] ?? [],
      categories: values["categories"] ?? [],
      authors: authors,
      draft: draftFlag,
      visibility: visibility,
      summary: summary,
      coverAttachmentID: attachments.coverAttachmentID,
      bodyMarkdown: parsedDocument.body.trimmingCharacters(in: .whitespacesAndNewlines),
      attachments: attachments.attachments,
      status: draftFlag ? .draft : .published,
      createdAt: date,
      updatedAt: fileModificationDate,
      repositoryPath: repositoryPath,
      repositorySHA: repositorySHA?.trimmedForPublishing.nilIfEmpty
    )
    importedDraft.repositoryImportFingerprint = importedDraft.repositoryContentFingerprint
    return importedDraft
  }

  private func importedAttachments(
    values: [String: [String]],
    imageReferences: [ImportedMarkdownImageReference],
    rootURL: URL,
    articleRepositoryPath: String,
    profile: SiteProfile
  ) -> (attachments: [DraftAttachment], coverAttachmentID: UUID?) {
    var attachments: [DraftAttachment] = []
    var indexesByPublishPath: [String: Int] = [:]

    for reference in imageReferences {
      guard let metadata = attachmentMetadata(
        imagePath: reference.path,
        altText: reference.altText,
        rootURL: rootURL,
        articleRepositoryPath: articleRepositoryPath,
        profile: profile
      ) else {
        continue
      }
      append(metadata, attachments: &attachments, indexesByPublishPath: &indexesByPublishPath)
    }

    var coverAttachmentID: UUID?
    if let coverPath = importedCoverPath(values) {
      if let existingIndex = indexesByPublishPath[coverPath] {
        coverAttachmentID = attachments[existingIndex].id
      } else if let metadata = attachmentMetadata(
        imagePath: coverPath,
        altText: "",
        rootURL: rootURL,
        articleRepositoryPath: articleRepositoryPath,
        profile: profile
      ) {
        let index = append(metadata, attachments: &attachments, indexesByPublishPath: &indexesByPublishPath)
        coverAttachmentID = attachments[index].id
      }
    }

    return (attachments, coverAttachmentID)
  }

  private func isCacheableImportedDraft(
    _ draft: ArticleDraft,
    parsedDocument: ParsedImportDocument
  ) -> Bool {
    var localPublishPaths = Set(parsedDocument.imageReferences.map {
      $0.path.trimmedForPublishing
    })
    if let coverPath = importedCoverPath(parsedDocument.values),
       let localCoverPath = markdownImagePath(coverPath) {
      localPublishPaths.insert(localCoverPath.trimmedForPublishing)
    }

    let attachmentsByPublishPath = Dictionary(
      draft.attachments.map { ($0.relativePublishPath, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return localPublishPaths.allSatisfy { publishPath in
      guard let attachment = attachmentsByPublishPath[publishPath],
            attachment.sourceFilePath?.nilIfEmpty != nil else {
        return false
      }
      return true
    }
  }

  @discardableResult
  private func append(
    _ attachment: DraftAttachment,
    attachments: inout [DraftAttachment],
    indexesByPublishPath: inout [String: Int]
  ) -> Int {
    let key = attachment.relativePublishPath
    if let existingIndex = indexesByPublishPath[key] {
      return existingIndex
    }

    let index = attachments.count
    attachments.append(attachment)
    indexesByPublishPath[key] = index
    return index
  }

  private func parseImportDocument(_ document: String) -> ParsedImportDocument {
    frontMatterParseObserver?()
    guard let parsed = DelimitedFrontMatterParser().split(document) else {
      return ParsedImportDocument(
        values: [:],
        body: document,
        imageReferences: markdownImageReferences(in: document)
      )
    }
    let values: [String: [String]]
    switch parsed.delimiter {
    case .yaml:
      values = parseYAMLFrontMatter(parsed.contentLines)
    case .toml:
      values = parseTOMLFrontMatter(parsed.contentLines)
    }
    return ParsedImportDocument(
      values: values,
      body: parsed.body,
      imageReferences: markdownImageReferences(in: parsed.body)
    )
  }

  private func parseYAMLFrontMatter(_ lines: [String]) -> [String: [String]] {
    var values: [String: [String]] = [:]
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmedForPublishing
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        index += 1
        continue
      }

      guard let separator = trimmed.firstIndex(of: ":") else {
        index += 1
        continue
      }

      let key = String(trimmed[..<separator]).trimmedForPublishing.lowercased()
      let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmedForPublishing

      if rawValue.isEmpty {
        var listValues: [String] = []
        var lookahead = index + 1
        while lookahead < lines.count {
          let item = lines[lookahead].trimmedForPublishing
          guard item.hasPrefix("- ") else { break }
          listValues.append(cleanScalar(String(item.dropFirst(2))))
          lookahead += 1
        }
        if !listValues.isEmpty {
          values[key] = listValues
          index = lookahead
          continue
        }
      } else {
        values[key] = parseScalarOrArray(rawValue)
      }

      index += 1
    }

    return values
  }

  private func parseTOMLFrontMatter(_ lines: [String]) -> [String: [String]] {
    var values: [String: [String]] = [:]

    for line in lines {
      let trimmed = line.trimmedForPublishing
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
        continue
      }

      let key = String(trimmed[..<separator]).trimmedForPublishing.lowercased()
      let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmedForPublishing
      values[key] = parseScalarOrArray(rawValue)
    }

    return values
  }

  private func parseScalarOrArray(_ rawValue: String) -> [String] {
    let value = rawValue.trimmedForPublishing
    if value.hasPrefix("["), value.hasSuffix("]") {
      let inner = String(value.dropFirst().dropLast())
      return inner
        .split(separator: ",")
        .map { cleanScalar(String($0)) }
        .filter { !$0.isEmpty }
    }
    return [cleanScalar(value)].filter { !$0.isEmpty }
  }

  private func cleanScalar(_ value: String) -> String {
    value
      .trimmedForPublishing
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      .trimmedForPublishing
  }

  private func parsedBool(_ value: String?) -> Bool? {
    switch value?.trimmedForPublishing.lowercased() {
    case "true", "yes", "1":
      return true
    case "false", "no", "0":
      return false
    default:
      return nil
    }
  }

  private func importedVisibility(
    values: [String: [String]],
    repositoryPath: String,
    profile: SiteProfile
  ) -> ArticleVisibility {
    if profile.isPrivateContentPath(repositoryPath) {
      return .private
    }
    if parsedBool(values["private"]?.first) == true {
      return .private
    }
    switch values["visibility"]?.first?.trimmedForPublishing.lowercased() {
    case "private":
      return .private
    default:
      return .public
    }
  }

  private func parsedDate(_ value: String?, profile: SiteProfile) -> Date? {
    guard let value = value?.nilIfEmpty else {
      return nil
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)

    for format in [profile.dateFormat, "yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return date
      }
    }

    return ISO8601DateFormatter().date(from: value)
  }

  private func repositoryRelativePath(rootURL: URL, fileURL: URL) -> String? {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath + "/") else {
      return nil
    }
    return String(filePath.dropFirst(rootPath.count + 1)).normalizedRelativePath()
  }

  private func safeMarkdownRepositoryPath(_ repositoryPath: String, profile: SiteProfile) -> String? {
    let displayPath = repositoryPath.components(separatedBy: " -> ").last?.trimmedForPublishing ?? repositoryPath.trimmedForPublishing
    guard !displayPath.isEmpty,
          !displayPath.hasPrefix("/"),
          !displayPath.contains("\\"),
          !displayPath.contains("://") else {
      return nil
    }

    let normalizedPath = displayPath.normalizedRelativePath()
    let pathComponents = normalizedPath.split(separator: "/")
    let pathExtension = (normalizedPath as NSString).pathExtension.lowercased()
    guard !normalizedPath.isEmpty,
          !pathComponents.contains(".."),
          ["md", "markdown", "mdx"].contains(pathExtension) else {
      return nil
    }

    return isImportableArticleRepositoryPath(normalizedPath, profile: profile) ? normalizedPath : nil
  }

  public func isImportableArticleRepositoryPath(
    _ repositoryPath: String,
    profile: SiteProfile
  ) -> Bool {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let pathExtension = (normalizedPath as NSString).pathExtension.lowercased()
    guard ["md", "markdown", "mdx"].contains(pathExtension) else {
      return false
    }

    let contentRoot = profile.contentRoot.normalizedRelativePath()
    let isPublicArticle = contentRoot.isEmpty
      || normalizedPath == contentRoot
      || normalizedPath.hasPrefix(contentRoot + "/")
    return isPublicArticle || profile.isPrivateContentPath(normalizedPath)
  }

  private func isRegularFile(at url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }

  private struct ImportedMarkdownImageReference {
    var altText: String
    var path: String
  }

  private struct ParsedImportDocument {
    var values: [String: [String]]
    var body: String
    var imageReferences: [ImportedMarkdownImageReference]
  }

  private func markdownImageReferences(in markdown: String) -> [ImportedMarkdownImageReference] {
    imageReferenceScanObserver?()
    let pattern = MarkdownPatterns.imagePattern
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }

    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return regex.matches(in: markdown, range: range).compactMap { match in
      guard
        let altRange = Range(match.range(at: 1), in: markdown),
        let pathRange = Range(match.range(at: 2), in: markdown),
        let imagePath = markdownImagePath(String(markdown[pathRange]))
      else {
        return nil
      }

      return ImportedMarkdownImageReference(
        altText: cleanScalar(String(markdown[altRange])),
        path: imagePath
      )
    }
  }

  private func markdownImagePath(_ rawValue: String) -> String? {
    var value = rawValue.trimmedForPublishing
    if value.hasPrefix("<"), let closingIndex = value.firstIndex(of: ">") {
      value = String(value[value.index(after: value.startIndex)..<closingIndex])
    } else if let firstToken = value.split(whereSeparator: \.isWhitespace).first {
      value = String(firstToken)
    }

    value = value.trimmedForPublishing
    guard !value.isEmpty,
          !value.hasPrefix("http://"),
          !value.hasPrefix("https://"),
          !value.hasPrefix("data:") else {
      return nil
    }
    return value
  }

  private func importedCoverPath(_ values: [String: [String]]) -> String? {
    values["cover"]?.first?.nilIfEmpty
      ?? values["image"]?.first?.nilIfEmpty
      ?? values["og_preview_img"]?.first?.nilIfEmpty
  }

  private func attachmentMetadata(
    imagePath: String,
    altText: String,
    rootURL: URL,
    articleRepositoryPath: String,
    profile: SiteProfile
  ) -> DraftAttachment? {
    let publishPath = imagePath.trimmedForPublishing
    guard !publishPath.isEmpty else {
      return nil
    }

    guard let repositoryPath = imageRepositoryPath(
      publishPath: publishPath,
      rootURL: rootURL,
      articleRepositoryPath: articleRepositoryPath,
      profile: profile
    ) else {
      return nil
    }
    let sourceURL = rootURL.appendingPathComponent(repositoryPath)
    let sourceFilePath: String?
    if fileManager.fileExists(atPath: sourceURL.path) {
      guard let safeSourceURL = canonicalRepositoryDescendant(
        candidateURL: sourceURL,
        rootURL: rootURL
      ), isRegularFile(at: safeSourceURL) else {
        return nil
      }
      sourceFilePath = safeSourceURL.path
    } else {
      sourceFilePath = nil
    }
    let byteSize = sourceFilePath.map { fileByteSize(at: URL(fileURLWithPath: $0)) } ?? 0
    let filename = filenameFromImagePath(repositoryPath) ?? filenameFromImagePath(publishPath) ?? "image"

    return DraftAttachment(
      originalFilename: filename,
      relativePublishPath: publishPath,
      repositoryPath: repositoryPath,
      altText: altText,
      byteSize: byteSize,
      sourceFilePath: sourceFilePath
    )
  }

  private func imageRepositoryPath(
    publishPath: String,
    rootURL: URL,
    articleRepositoryPath: String,
    profile: SiteProfile
  ) -> String? {
    let filePath = imageFilePathComponent(publishPath)
    let assetRoot = profile.assetRoot.normalizedRelativePath()
    var candidates: [String] = []

    if publishPath.hasPrefix("/") {
      let absolutePath = filePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).normalizedRelativePath()
      if !assetRoot.isEmpty, absolutePath == assetRoot || absolutePath.hasPrefix(assetRoot + "/") {
        candidates.append(absolutePath)
      } else if !assetRoot.isEmpty {
        candidates.append((assetRoot + "/" + absolutePath).normalizedRelativePath())
      }
      candidates.append(absolutePath)
    } else {
      let normalized = filePath.normalizedRelativePath()
      candidates.append(normalized)

      let articleDirectory = articleRepositoryPath
        .normalizedRelativePath()
        .split(separator: "/")
        .dropLast()
        .map(String.init)
        .joined(separator: "/")
      if !articleDirectory.isEmpty {
        candidates.append((articleDirectory + "/" + normalized).normalizedRelativePath())
      }
    }

    let safeCandidates = candidates.compactMap(safeImageRepositoryPath)
    return safeCandidates.first { candidate in
      let candidateURL = rootURL.appendingPathComponent(candidate)
      guard fileManager.fileExists(atPath: candidateURL.path) else { return false }
      return canonicalRepositoryDescendant(candidateURL: candidateURL, rootURL: rootURL) != nil
    } ?? safeCandidates.first
  }

  private func safeImageRepositoryPath(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
          !value.hasPrefix("/"),
          !value.contains("\\"),
          !value.contains("\0") else {
      return nil
    }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { $0 == ".." }) else {
      return nil
    }
    let normalized = value.normalizedRelativePath()
    let normalizedComponents = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard !normalized.isEmpty,
          !normalized.hasPrefix("/"),
          !normalizedComponents.contains(where: { $0 == ".." }) else {
      return nil
    }
    return normalized
  }

  private func canonicalRepositoryDescendant(candidateURL: URL, rootURL: URL) -> URL? {
    let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let canonicalCandidate = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
    guard canonicalCandidate.path.hasPrefix(rootPath) else {
      return nil
    }
    return canonicalCandidate
  }

  private func imageFilePathComponent(_ path: String) -> String {
    let withoutFragment = path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
    return withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutFragment
  }

  private func filenameFromImagePath(_ path: String) -> String? {
    URL(fileURLWithPath: imageFilePathComponent(path)).lastPathComponent.nilIfEmpty
  }

  private func fileByteSize(at url: URL) -> Int64 {
    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
  }

  private func slugFromPath(_ path: String) -> String? {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let pattern = #"^\d{4}-\d{2}-\d{2}-(.+)$"#
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..<stem.endIndex, in: stem)),
       let range = Range(match.range(at: 1), in: stem) {
      return String(stem[range]).nilIfEmpty
    }
    return stem.nilIfEmpty
  }

  private func dateFromPath(_ path: String) -> Date? {
    let stem = URL(fileURLWithPath: path).lastPathComponent
    let pattern = #"^(\d{4})-(\d{2})-(\d{2})-"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..<stem.endIndex, in: stem)),
          match.numberOfRanges == 4,
          let yearRange = Range(match.range(at: 1), in: stem),
          let monthRange = Range(match.range(at: 2), in: stem),
          let dayRange = Range(match.range(at: 3), in: stem)
    else {
      return nil
    }

    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = Int(stem[yearRange])
    components.month = Int(stem[monthRange])
    components.day = Int(stem[dayRange])
    return components.date
  }

  private func humanizedTitle(from path: String) -> String {
    let stem = slugFromPath(path) ?? "未命名文章"
    return stem
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .nilIfEmpty ?? "未命名文章"
  }
}
