import AppKit
import Foundation
import PDFKit

public final class KnowledgeLibraryService: @unchecked Sendable {
  public static let parserVersion = 3

  public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
    let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return supportURL
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("KnowledgeLibrary", isDirectory: true)
  }

  public static func applyPendingRestoreIfNeeded(
    rootURL: URL? = nil,
    fileManager: FileManager = .default
  ) -> KnowledgeLibraryRestoreStartupOutcome {
    let resolvedRootURL = rootURL ?? defaultRootURL(fileManager: fileManager)
    do {
      let result = try KnowledgeLibraryBackupService(
        rootURL: resolvedRootURL,
        fileManager: fileManager
      ).applyPendingRestoreIfNeeded()
      return result.map(KnowledgeLibraryRestoreStartupOutcome.restored) ?? .none
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  public let rootURL: URL
  private let databaseLock = NSLock()
  private let storageMutationLock = NSLock()
  private var cachedDatabase: KnowledgeDatabase?
  private let semanticBackfillLock = NSLock()
  private var backfilledSemanticModelIDs: Set<String> = []
  private let chunkingService: KnowledgeChunkingService
  private let semanticEmbeddingService: KnowledgeSemanticEmbeddingService
  private let searchPresentationService = KnowledgeSearchPresentationService()
  private let searchDiversificationService = KnowledgeSearchDiversificationService()
  private let revisionDifferenceService = KnowledgeRevisionDifferenceService()
  private let webContentSanitizer = KnowledgeWebContentSanitizer()
  private let epubParser = KnowledgeEPUBParser()
  private let pdfOCRService = KnowledgePDFOCRService()
  private let fileManager: FileManager

  public init(
    rootURL: URL? = nil,
    chunkingService: KnowledgeChunkingService = KnowledgeChunkingService(),
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
    self.chunkingService = chunkingService
    self.semanticEmbeddingService = KnowledgeSemanticEmbeddingService()
    self.fileManager = fileManager
  }

  public func documents() throws -> [KnowledgeDocument] {
    let database = try database()
    var documents = try database.documents()
    for index in documents.indices where documents[index].sourceByteCount == 0 {
      guard let revision = try database.currentRevision(documentID: documents[index].id) else { continue }
      let references = [revision.originalStorageReference, revision.normalizedStorageReference]
        .compactMap { $0?.nilIfEmpty }
      let byteCount = references.lazy.compactMap { reference -> Int64? in
        guard let url = self.safeStorageFileURL(for: reference) else { return nil }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return nil }
        return Int64(size)
      }.first
      guard let byteCount else { continue }
      documents[index].sourceByteCount = byteCount
      try? database.setSourceByteCount(byteCount, documentID: documents[index].id)
    }
    return documents
  }

  public func documentsAsync() async throws -> [KnowledgeDocument] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.documents()
    }.value
  }

  public func document(id: UUID) throws -> KnowledgeDocument? {
    try database().document(id: id)
  }

  public func folders() throws -> [KnowledgeFolder] {
    try database().folders()
  }

  public func foldersAsync() async throws -> [KnowledgeFolder] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.folders()
    }.value
  }

  public func recycledDocuments() throws -> [KnowledgeRecycledDocument] {
    try database().recycledDocuments()
  }

  public func recycledDocumentsAsync() async throws -> [KnowledgeRecycledDocument] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.recycledDocuments()
    }.value
  }

  @discardableResult
  public func createFolder(name: String) throws -> KnowledgeFolder {
    try database().createFolder(name: name)
  }

  @discardableResult
  public func renameFolder(id: UUID, name: String) throws -> KnowledgeFolder {
    try database().renameFolder(id: id, name: name)
  }

  public func deleteFolder(id: UUID) throws {
    try database().deleteFolder(id: id)
  }

  public func setFolder(_ folderID: UUID?, documentID: UUID) throws {
    try database().setFolder(folderID, documentID: documentID)
  }

  public func setFolder(_ folderID: UUID?, documentIDs: Set<UUID>) throws {
    try database().setFolder(folderID, documentIDs: documentIDs)
  }

  public func addTags(_ tags: [String], documentIDs: Set<UUID>) throws {
    let normalizedTags = normalizedMetadataValues(tags, maximumCount: 50, maximumLength: 80)
    guard !normalizedTags.isEmpty else {
      throw KnowledgeLibraryError.invalidMetadata("请至少输入一个有效标签。")
    }
    try database().addTags(normalizedTags, documentIDs: documentIDs)
    invalidateSemanticBackfillCache()
  }

  @discardableResult
  public func updateMetadata(
    documentID: UUID,
    metadata: KnowledgeDocumentMetadata
  ) throws -> KnowledgeDocument {
    let title = metadata.title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
    guard !title.isEmpty, title.count <= 300 else {
      throw KnowledgeLibraryError.invalidMetadata("标题不能为空，且最多 300 个字符。")
    }
    let normalized = KnowledgeDocumentMetadata(
      kind: metadata.kind,
      title: title,
      authors: normalizedMetadataValues(metadata.authors, maximumCount: 30, maximumLength: 120),
      language: metadata.language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      summary: String(metadata.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000)),
      tags: normalizedMetadataValues(metadata.tags, maximumCount: 50, maximumLength: 80)
    )
    try database().updateMetadata(documentID: documentID, metadata: normalized)
    invalidateSemanticBackfillCache()
    guard let document = try database().document(id: documentID) else {
      throw KnowledgeLibraryError.missingDocument
    }
    return document
  }

  public func normalizedText(documentID: UUID) throws -> String {
    guard let revision = try database().currentRevision(documentID: documentID) else {
      throw KnowledgeLibraryError.missingDocument
    }
    let url = rootURL.appendingPathComponent(revision.normalizedStorageReference)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw KnowledgeLibraryError.unreadableSource(url.path)
    }
    return text
  }

  public func normalizedTextAsync(documentID: UUID) async throws -> String {
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.normalizedText(documentID: documentID)
    }.value
  }

  public func revisions(documentID: UUID) throws -> [KnowledgeDocumentRevision] {
    try database().revisions(documentID: documentID)
  }

  public func normalizedText(revisionID: UUID) throws -> String {
    guard let revision = try database().revision(id: revisionID) else {
      throw KnowledgeLibraryError.missingRevision
    }
    let url = rootURL.appendingPathComponent(revision.normalizedStorageReference)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw KnowledgeLibraryError.unreadableSource(url.path)
    }
    return text
  }

  @discardableResult
  public func restoreRevision(
    documentID: UUID,
    revisionID: UUID
  ) throws -> KnowledgeDocument {
    let database = try database()
    var document = try database.restoreRevision(documentID: documentID, revisionID: revisionID)
    if let revision = try database.revision(id: revisionID),
       let byteCount = storedByteCount(for: revision) {
      try database.setSourceByteCount(byteCount, documentID: documentID)
      document.sourceByteCount = byteCount
    }
    invalidateSemanticBackfillCache()
    return document
  }

  public func revisionDifference(
    documentID: UUID,
    revisionID: UUID
  ) throws -> KnowledgeRevisionDifference {
    guard let currentRevision = try database().currentRevision(documentID: documentID) else {
      throw KnowledgeLibraryError.missingDocument
    }
    guard let comparedRevision = try database().revision(id: revisionID),
          comparedRevision.documentID == documentID else {
      throw KnowledgeLibraryError.missingRevision
    }
    return revisionDifferenceService.difference(
      previousText: try normalizedText(revisionID: revisionID),
      currentText: try normalizedText(revisionID: currentRevision.id)
    )
  }

  public func makeSourceRefreshPreview(
    documentID: UUID
  ) async throws -> KnowledgeSourceRefreshPreview {
    guard let document = try document(id: documentID),
          let currentRevision = try database().currentRevision(documentID: documentID),
          let sourceURL = document.sourceURL else {
      throw KnowledgeLibraryError.sourceRefreshUnavailable
    }

    var importPreview: KnowledgeImportPreview
    if sourceURL.isFileURL {
      importPreview = try await makeImportPreview(sourceURL: sourceURL)
    } else if ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") {
      importPreview = try await makeWebImportPreview(url: sourceURL)
    } else {
      throw KnowledgeLibraryError.sourceRefreshUnavailable
    }
    guard importPreview.candidates.count == 1 else {
      throw KnowledgeLibraryError.sourceRefreshUnavailable
    }

    var candidate = importPreview.candidates[0]
    candidate.existingDocumentID = documentID
    candidate.disposition = candidate.normalizedContentHash == currentRevision.normalizedContentHash
      ? .duplicate
      : .update
    candidate.kind = document.kind
    candidate.title = document.title
    candidate.authors = document.authors
    candidate.language = document.language
    candidate.summary = document.summary
    candidate.tags = document.tags
    importPreview.candidates = [candidate]
    let previousText = try normalizedText(revisionID: currentRevision.id)
    return KnowledgeSourceRefreshPreview(
      documentID: documentID,
      currentRevision: currentRevision,
      importPreview: importPreview,
      difference: revisionDifferenceService.difference(
        previousText: previousText,
        currentText: candidate.normalizedText
      )
    )
  }

  public func applySourceRefresh(
    _ preview: KnowledgeSourceRefreshPreview
  ) async throws -> KnowledgeImportResult {
    guard preview.importPreview.candidates.allSatisfy({ candidate in
      candidate.existingDocumentID == preview.documentID
    }) else {
      throw KnowledgeLibraryError.sourceRefreshUnavailable
    }
    return try await commit(preview.importPreview, destination: .preserveExisting)
  }

  public func libraryHealth() async throws -> KnowledgeLibraryHealthSnapshot {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.libraryHealthSynchronously()
    }.value
  }

  public func makeLocalContentRepairPreviews(
    documentIDs: Set<UUID>? = nil,
    includingCurrentParserVersion: Bool = false
  ) async throws -> [KnowledgeSourceRefreshPreview] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.makeLocalContentRepairPreviewsSynchronously(
        documentIDs: documentIDs,
        includingCurrentParserVersion: includingCurrentParserVersion
      )
    }.value
  }

  public func applyLocalContentRepairs(
    _ previews: [KnowledgeSourceRefreshPreview]
  ) async throws -> KnowledgeImportResult {
    guard !previews.isEmpty else {
      return KnowledgeImportResult(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    let candidates = previews.flatMap(\.importPreview.candidates)
    guard candidates.count == previews.count,
          zip(previews, candidates).allSatisfy({ preview, candidate in
            candidate.existingDocumentID == preview.documentID
              && candidate.disposition == .update
          }) else {
      throw KnowledgeLibraryError.contentRepairUnavailable("修复预览与资料版本不匹配。")
    }
    return try await commit(
      KnowledgeImportPreview(sourceName: "资料质量修复", candidates: candidates),
      destination: .preserveExisting
    )
  }

  public func makeImportPreview(
    sourceURL: URL,
    options: KnowledgeImportOptions = KnowledgeImportOptions()
  ) async throws -> KnowledgeImportPreview {
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try service.makeImportPreviewSynchronously(sourceURL: sourceURL, options: options)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func makeImportPreview(
    sourceURLs: [URL],
    options: KnowledgeImportOptions = KnowledgeImportOptions()
  ) async throws -> KnowledgeImportPreview {
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try service.makeImportPreviewSynchronously(
        sourceURLs: sourceURLs,
        options: options
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func makeWebImportPreview(url: URL) async throws -> KnowledgeImportPreview {
    var request = URLRequest(url: url)
    request.timeoutInterval = 25
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("text/html,application/xhtml+xml,text/plain;q=0.8", forHTTPHeaderField: "Accept")

    let download: KnowledgeWebDownloadResponse
    do {
      download = try await KnowledgeWebDownloadClient().download(
        request: request,
        maximumByteCount: 12 * 1_024 * 1_024
      )
    } catch KnowledgeWebDownloadError.invalidURL {
      throw KnowledgeLibraryError.invalidWebURL
    } catch KnowledgeWebDownloadError.byteLimitExceeded {
      throw KnowledgeLibraryError.sourceLimitExceeded("网页内容超过 12 MB，下载已停止，请改用文件导入。")
    } catch {
      throw KnowledgeLibraryError.networkFailure(error.localizedDescription)
    }
    let finalURL = download.response.url ?? url

    let candidate = try candidate(
      data: download.data,
      sourceName: finalURL.host ?? finalURL.absoluteString,
      sourceURL: finalURL,
      fileExtension: finalURL.pathExtension.nilIfEmpty ?? "html",
      preferredKind: .webpage,
      sourceModifiedAt: nil
    )
    return KnowledgeImportPreview(sourceName: finalURL.absoluteString, candidates: [candidate])
  }

  public func makeBrowserImportPreview(
    capture: KnowledgeBrowserCapture
  ) async throws -> KnowledgeImportPreview {
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.makeBrowserImportPreviewSynchronously(capture)
    }.value
  }

  public func commit(
    _ preview: KnowledgeImportPreview,
    destination: KnowledgeImportDestination = .preserveExisting
  ) async throws -> KnowledgeImportResult {
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.commitSynchronously(preview, destination: destination)
    }.value
  }

  public func setAllowsAIUse(_ allowsAIUse: Bool, documentID: UUID) throws {
    try database().setAllowsAIUse(allowsAIUse, documentID: documentID)
  }

  public func setAllowsAIUse(_ allowsAIUse: Bool, documentIDs: Set<UUID>) throws {
    try database().setAllowsAIUse(allowsAIUse, documentIDs: documentIDs)
  }

  public func moveToRecycleBin(documentIDs: Set<UUID>) throws {
    try database().moveToRecycleBin(documentIDs: documentIDs)
  }

  public func restoreFromRecycleBin(documentIDs: Set<UUID>) throws {
    try database().restoreFromRecycleBin(documentIDs: documentIDs)
  }

  public func annotations(documentID: UUID) throws -> [KnowledgeAnnotation] {
    try database().annotations(documentID: documentID)
  }

  @discardableResult
  public func saveAnnotation(_ annotation: KnowledgeAnnotation) throws -> KnowledgeAnnotation {
    let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty, note.count <= 20_000 else {
      throw KnowledgeLibraryError.invalidMetadata("标注笔记不能为空，且最多 20,000 个字符。")
    }
    var normalized = annotation
    normalized.note = note
    normalized.highlightedText = String(
      annotation.highlightedText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000)
    )
    normalized.locator = annotation.locator?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    normalized.updatedAt = Date()
    try database().saveAnnotation(normalized)
    return normalized
  }

  public func deleteAnnotation(id: UUID) throws {
    try database().deleteAnnotation(id: id)
  }

  public func backlinks(documentID: UUID) throws -> [KnowledgeBacklink] {
    try database().backlinks(documentID: documentID)
  }

  public func recordBacklinks(
    citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) throws {
    guard !target.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !target.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw KnowledgeLibraryError.invalidMetadata("反向链接目标缺少标题或标识。")
    }
    try database().recordBacklinks(citations: citations, target: target)
  }

  public func pinnedDocumentIDs() throws -> Set<UUID> {
    try database().pinnedDocumentIDs()
  }

  public func pinnedDocumentIDsAsync() async throws -> Set<UUID> {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.pinnedDocumentIDs()
    }.value
  }

  public func setPinned(_ pinned: Bool, documentID: UUID) throws {
    try database().setPinned(pinned, documentID: documentID)
  }

  public func exportDocuments(
    documentIDs: Set<UUID>,
    to destinationDirectory: URL
  ) async throws -> KnowledgeBatchExportReport {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.exportDocumentsSynchronously(
        documentIDs: documentIDs,
        to: destinationDirectory
      )
    }.value
  }

  public func createBackup(
    at destinationURL: URL,
    applicationVersion: String? = nil
  ) async throws -> KnowledgeLibraryBackupPreview {
    let service = self
    let resolvedVersion = applicationVersion
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
    return try await Task.detached(priority: .utility) {
      try KnowledgeLibraryBackupService(rootURL: service.rootURL, fileManager: service.fileManager)
        .createBackup(
          at: destinationURL,
          database: try service.database(),
          applicationVersion: resolvedVersion
        )
    }.value
  }

  public func inspectBackup(at backupURL: URL) async throws -> KnowledgeLibraryBackupPreview {
    let service = self
    return try await Task.detached(priority: .utility) {
      try KnowledgeLibraryBackupService(rootURL: service.rootURL, fileManager: service.fileManager)
        .inspectBackup(at: backupURL)
    }.value
  }

  public func stageRestore(from backupURL: URL) async throws -> KnowledgeLibraryBackupPreview {
    let service = self
    return try await Task.detached(priority: .utility) {
      try KnowledgeLibraryBackupService(rootURL: service.rootURL, fileManager: service.fileManager)
        .stageRestore(from: backupURL)
    }.value
  }

  @discardableResult
  public func deleteDocument(id: UUID) throws -> KnowledgeDocumentDeletionReport {
    storageMutationLock.lock()
    defer { storageMutationLock.unlock() }
    let outcome = try database().deleteDocument(id: id)
    var removedStoredFileCount = 0
    var failedStoredFileCount = 0

    for reference in outcome.unreferencedStorageReferences {
      guard let fileURL = safeStorageFileURL(for: reference) else {
        failedStoredFileCount += 1
        continue
      }
      guard fileManager.fileExists(atPath: fileURL.path) else { continue }
      do {
        let values = try fileURL.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          failedStoredFileCount += 1
          continue
        }
        try fileManager.removeItem(at: fileURL)
        removedStoredFileCount += 1
      } catch {
        failedStoredFileCount += 1
      }
    }

    return KnowledgeDocumentDeletionReport(
      removedStoredFileCount: removedStoredFileCount,
      failedStoredFileCount: failedStoredFileCount
    )
  }

  private func safeStorageFileURL(for reference: String) -> URL? {
    let components = reference.split(separator: "/", omittingEmptySubsequences: false)
    guard !reference.hasPrefix("/"),
          !reference.contains("\\"),
          components.count >= 2,
          components.first == "blobs" || components.first == "normalized",
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      return nil
    }

    let candidateURL = rootURL.appendingPathComponent(reference).standardizedFileURL
    let resolvedRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedCandidateURL = candidateURL.resolvingSymlinksInPath().standardizedFileURL
    let rootPathPrefix = resolvedRootURL.path.hasSuffix("/")
      ? resolvedRootURL.path
      : resolvedRootURL.path + "/"
    guard resolvedCandidateURL.path.hasPrefix(rootPathPrefix) else { return nil }
    return candidateURL
  }

  private func exportDocumentsSynchronously(
    documentIDs: Set<UUID>,
    to destinationDirectory: URL
  ) throws -> KnowledgeBatchExportReport {
    guard !documentIDs.isEmpty else {
      return KnowledgeBatchExportReport(
        exportedDocumentCount: 0,
        destinationDirectory: destinationDirectory
      )
    }
    let didAccess = destinationDirectory.startAccessingSecurityScopedResource()
    defer {
      if didAccess { destinationDirectory.stopAccessingSecurityScopedResource() }
    }

    storageMutationLock.lock()
    defer { storageMutationLock.unlock() }
    do {
      try fileManager.createDirectory(
        at: destinationDirectory,
        withIntermediateDirectories: true
      )
      let values = try destinationDirectory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw KnowledgeLibraryError.exportFailure("目标必须是普通文件夹。")
      }

      let selectedDocuments = try documents()
        .filter { documentIDs.contains($0.id) }
        .sorted { lhs, rhs in
          lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
      guard selectedDocuments.count == documentIDs.count else {
        throw KnowledgeLibraryError.missingDocument
      }
      let exportedAt = ISO8601DateFormatter().string(from: Date())
      for document in selectedDocuments {
        try Task.checkCancellation()
        let body = try normalizedText(documentID: document.id)
        let frontMatter = [
          "---",
          "id: \(jsonEncoded(document.id.uuidString))",
          "title: \(jsonEncoded(document.title))",
          "kind: \(jsonEncoded(document.kind.rawValue))",
          "authors: \(jsonEncoded(document.authors))",
          "language: \(document.language.map(jsonEncoded) ?? "null")",
          "tags: \(jsonEncoded(document.tags))",
          "source: \(document.sourceURL.map { jsonEncoded($0.absoluteString) } ?? "null")",
          "imported_at: \(jsonEncoded(ISO8601DateFormatter().string(from: document.importedAt)))",
          "exported_at: \(jsonEncoded(exportedAt))",
          "---",
          "",
        ].joined(separator: "\n")
        let fileURL = destinationDirectory.appendingPathComponent(
          "\(safeExportFilename(document.title))-\(document.id.uuidString.prefix(8)).md"
        )
        try (frontMatter + body).write(to: fileURL, atomically: true, encoding: .utf8)
      }
      return KnowledgeBatchExportReport(
        exportedDocumentCount: selectedDocuments.count,
        destinationDirectory: destinationDirectory
      )
    } catch let error as KnowledgeLibraryError {
      throw error
    } catch {
      throw KnowledgeLibraryError.exportFailure(error.localizedDescription)
    }
  }

  private func safeExportFilename(_ title: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
      .union(.controlCharacters)
    let sanitized = title
      .components(separatedBy: forbidden)
      .joined(separator: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return String((sanitized.nilIfEmpty ?? "未命名资料").prefix(100))
  }

  private func jsonEncoded<T: Encodable>(_ value: T) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  public func search(
    query: String,
    limit: Int = 30,
    onlyAIAllowed: Bool = false,
    documentIDs: Set<UUID>? = nil,
    requiredSignal: KnowledgeRetrievalSignal? = nil
  ) throws -> [KnowledgeSearchResult] {
    let trimmedQuery = query.trimmedForPublishing
    guard !trimmedQuery.isEmpty, limit > 0 else { return [] }
    let candidateLimit = min(max(limit * 4, 48), 240)
    let database = try database()
    let fullTextResults = try database.search(
      query: trimmedQuery,
      limit: candidateLimit,
      onlyAIAllowed: onlyAIAllowed,
      documentIDs: documentIDs
    ).map { result in
      var explainedResult = result
      explainedResult.signals = searchPresentationService.lexicalSignals(
        for: result,
        query: trimmedQuery
      )
      return explainedResult
    }

    let queryVectors = semanticEmbeddingService.vectors(for: trimmedQuery)
    var semanticRankings: [[KnowledgeSearchResult]] = []
    for queryVector in queryVectors {
      try ensureSemanticIndex(for: queryVector, database: database)
      semanticRankings.append(try database.semanticSearch(
        queryVector: queryVector,
        limit: candidateLimit,
        onlyAIAllowed: onlyAIAllowed,
        documentIDs: documentIDs
      ))
    }

    let eligibleFullTextResults: [KnowledgeSearchResult]
    let eligibleSemanticRankings: [[KnowledgeSearchResult]]
    switch requiredSignal {
    case nil:
      eligibleFullTextResults = fullTextResults
      eligibleSemanticRankings = semanticRankings
    case .semantic:
      eligibleFullTextResults = []
      eligibleSemanticRankings = semanticRankings
    case .title, .fullText:
      let eligibleFullText = fullTextResults.filter { result in
        requiredSignal.map(result.signals.contains) ?? true
      }
      let eligibleResultIDs = Set(eligibleFullText.map(\.id))
      eligibleFullTextResults = eligibleFullText
      eligibleSemanticRankings = semanticRankings.map { ranking in
        ranking.filter { eligibleResultIDs.contains($0.id) }
      }
    }

    return fusedSearchResults(
      fullText: eligibleFullTextResults,
      semanticRankings: eligibleSemanticRankings,
      limit: limit
    )
  }

  public func searchAsync(
    query: String,
    limit: Int = 30,
    onlyAIAllowed: Bool = false,
    documentIDs: Set<UUID>? = nil,
    requiredSignal: KnowledgeRetrievalSignal? = nil
  ) async throws -> [KnowledgeSearchResult] {
    semanticEmbeddingService.prepareContextualModelIfNeeded(for: query)
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.search(
        query: query,
        limit: limit,
        onlyAIAllowed: onlyAIAllowed,
        documentIDs: documentIDs,
        requiredSignal: requiredSignal
      )
    }.value
  }

  public func relatedChapters(
    documentID: UUID,
    anchorChunkID: UUID? = nil,
    limit: Int = 8
  ) throws -> [KnowledgeRelatedChapter] {
    guard limit > 0 else { return [] }
    let database = try database()
    let records = try database.semanticIndexRecords()
    let documentRecords = records.filter { $0.document.id == documentID }
    guard let anchor = anchorChunkID.flatMap({ chunkID in
      documentRecords.first { $0.chunk.id == chunkID }
    }) ?? documentRecords.first else { return [] }

    let anchorText: String
    if anchorChunkID != nil {
      anchorText = anchor.searchableText
    } else {
      anchorText = ([
        anchor.document.title,
        anchor.document.summary,
        anchor.document.authors.joined(separator: " "),
        anchor.document.tags.joined(separator: " "),
      ] + documentRecords.prefix(3).map(\.chunk.content))
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    var semanticScores: [UUID: Double] = [:]
    for queryVector in semanticEmbeddingService.vectors(for: anchorText) {
      try ensureSemanticIndex(for: queryVector, database: database)
      let matches = try database.semanticSearch(
        queryVector: queryVector,
        limit: min(max(records.count, limit * 12), 240),
        onlyAIAllowed: false
      )
      for match in matches {
        semanticScores[match.chunk.id] = max(
          semanticScores[match.chunk.id, default: 0],
          match.score
        )
      }
    }

    return KnowledgeRelatedChapterRankingService().recommendations(
      anchor: anchor,
      candidates: records,
      semanticScores: semanticScores,
      limit: limit
    )
  }

  public func relatedChaptersAsync(
    documentID: UUID,
    anchorChunkID: UUID? = nil,
    limit: Int = 8
  ) async throws -> [KnowledgeRelatedChapter] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.relatedChapters(
        documentID: documentID,
        anchorChunkID: anchorChunkID,
        limit: limit
      )
    }.value
  }

  public func context(
    query: String,
    documentIDs: Set<UUID>? = nil,
    maximumCitations: Int = 8,
    tokenBudget: Int = 2_200
  ) throws -> KnowledgeContextSnapshot? {
    let candidates = try search(
      query: query,
      limit: max(maximumCitations * 4, 16),
      onlyAIAllowed: true,
      documentIDs: documentIDs
    )
    guard !candidates.isEmpty else { return nil }

    var citations: [KnowledgeCitation] = []
    var usedTokens = 0
    var documentUseCounts: [UUID: Int] = [:]

    for result in candidates {
      guard citations.count < maximumCitations else { break }
      let currentDocumentCount = documentUseCounts[result.document.id, default: 0]
      guard currentDocumentCount < 2 else { continue }
      let remainingBudget = tokenBudget - usedTokens
      guard remainingBudget > 100 else { break }

      let maximumCharacters = min(1_500, remainingBudget * 3)
      let excerpt = clipped(result.chunk.content, maximumCharacters: maximumCharacters)
      let estimatedTokens = max(1, Int(ceil(Double(excerpt.count) / 3.0)))
      guard estimatedTokens <= remainingBudget else { continue }

      citations.append(KnowledgeCitation(
        id: "K\(citations.count + 1)",
        documentID: result.document.id,
        chunkID: result.chunk.id,
        title: result.document.title,
        authors: result.document.authors,
        locator: result.chunk.locator?.nilIfEmpty ?? result.chunk.headingPath?.nilIfEmpty,
        excerpt: excerpt,
        sourceURL: result.document.sourceURL
      ))
      usedTokens += estimatedTokens
      documentUseCounts[result.document.id] = currentDocumentCount + 1
    }

    guard !citations.isEmpty else { return nil }
    return KnowledgeContextSnapshot(query: query, citations: citations)
  }

  public func contextAsync(
    query: String,
    documentIDs: Set<UUID>? = nil,
    maximumCitations: Int = 8,
    tokenBudget: Int = 2_200
  ) async throws -> KnowledgeContextSnapshot? {
    semanticEmbeddingService.prepareContextualModelIfNeeded(for: query)
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.context(
        query: query,
        documentIDs: documentIDs,
        maximumCitations: maximumCitations,
        tokenBudget: tokenBudget
      )
    }.value
  }

  public func repairSemanticVectors() async throws -> KnowledgeSemanticRepairReport {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.repairSemanticVectorsSynchronously()
    }.value
  }

  public func repairSemanticVectors(
    documentIDs: Set<UUID>
  ) async throws -> KnowledgeSemanticRepairReport {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.repairSemanticVectorsSynchronously(documentIDs: documentIDs)
    }.value
  }

  private func ensureSemanticIndex(
    for queryVector: KnowledgeSemanticVector,
    database: KnowledgeDatabase
  ) throws {
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }
    let modelIdentifier = queryVector.modelIdentifier
    guard !backfilledSemanticModelIDs.contains(modelIdentifier) else { return }

    let repairRecords = try database.semanticIndexRecordsNeedingRepair(
      modelIdentifier: modelIdentifier,
      expectedDimension: queryVector.values.count
    )
    let embeddings = repairRecords.compactMap { record -> KnowledgeChunkEmbedding? in
      guard let vector = semanticEmbeddingService.vector(
        for: record.searchableText,
        modelIdentifier: modelIdentifier
      ) else {
        return nil
      }
      return KnowledgeChunkEmbedding(
        chunkID: record.chunk.id,
        revisionID: record.chunk.revisionID,
        vector: vector
      )
    }
    try database.upsertSemanticEmbeddings(embeddings)
    backfilledSemanticModelIDs.insert(modelIdentifier)
  }

  private func repairSemanticVectorsSynchronously() throws -> KnowledgeSemanticRepairReport {
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }

    let database = try database()
    let records = try database.semanticIndexRecords()
    var modelIdentifiers = Set<String>()
    let embeddings = records.flatMap { record in
      semanticEmbeddingService.vectors(for: record.searchableText).map { vector in
        modelIdentifiers.insert(vector.modelIdentifier)
        return KnowledgeChunkEmbedding(
          chunkID: record.chunk.id,
          revisionID: record.chunk.revisionID,
          vector: vector
        )
      }
    }
    try database.upsertSemanticEmbeddings(embeddings)
    backfilledSemanticModelIDs.removeAll()
    return KnowledgeSemanticRepairReport(
      scannedChunkCount: records.count,
      regeneratedVectorCount: embeddings.count,
      modelIdentifiers: Array(modelIdentifiers)
    )
  }

  private func repairSemanticVectorsSynchronously(
    documentIDs: Set<UUID>
  ) throws -> KnowledgeSemanticRepairReport {
    guard !documentIDs.isEmpty else {
      return KnowledgeSemanticRepairReport(
        scannedChunkCount: 0,
        regeneratedVectorCount: 0,
        modelIdentifiers: []
      )
    }
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }

    let database = try database()
    let records = try database.semanticIndexRecords().filter {
      documentIDs.contains($0.document.id)
    }
    var modelIdentifiers = Set<String>()
    let embeddings = records.flatMap { record in
      semanticEmbeddingService.vectors(for: record.searchableText).map { vector in
        modelIdentifiers.insert(vector.modelIdentifier)
        return KnowledgeChunkEmbedding(
          chunkID: record.chunk.id,
          revisionID: record.chunk.revisionID,
          vector: vector
        )
      }
    }
    try database.replaceSemanticEmbeddings(
      documentIDs: documentIDs,
      embeddings: embeddings
    )
    backfilledSemanticModelIDs.removeAll()
    return KnowledgeSemanticRepairReport(
      scannedChunkCount: records.count,
      regeneratedVectorCount: embeddings.count,
      modelIdentifiers: Array(modelIdentifiers)
    )
  }

  private func fusedSearchResults(
    fullText: [KnowledgeSearchResult],
    semanticRankings: [[KnowledgeSearchResult]],
    limit: Int
  ) -> [KnowledgeSearchResult] {
    let rankConstant = 60.0
    var resultByID: [UUID: KnowledgeSearchResult] = [:]
    var scoreByID: [UUID: Double] = [:]
    var signalsByID: [UUID: Set<KnowledgeRetrievalSignal>] = [:]

    for (offset, result) in fullText.enumerated() {
      let contribution = 0.62 / (rankConstant + Double(offset + 1))
      resultByID[result.id] = result
      scoreByID[result.id, default: 0] += contribution
      signalsByID[result.id, default: []].formUnion(result.signals)
    }

    var bestSemanticContribution: [UUID: Double] = [:]
    var bestSemanticResult: [UUID: KnowledgeSearchResult] = [:]
    for ranking in semanticRankings {
      for (offset, result) in ranking.enumerated() {
        let rankContribution = 0.38 / (rankConstant + Double(offset + 1))
        let similarityContribution = max(0, result.score) * 0.0015
        let contribution = rankContribution + similarityContribution
        if contribution > bestSemanticContribution[result.id, default: -.infinity] {
          bestSemanticContribution[result.id] = contribution
          bestSemanticResult[result.id] = result
        }
      }
    }

    for (id, contribution) in bestSemanticContribution {
      if resultByID[id] == nil, let semanticResult = bestSemanticResult[id] {
        resultByID[id] = semanticResult
      }
      scoreByID[id, default: 0] += contribution
      signalsByID[id, default: []].formUnion([.semantic])
    }

    let fused = resultByID.compactMap { id, storedResult in
      var result = storedResult
      result.score = scoreByID[id, default: 0]
      result.signals = signalsByID[id, default: []]
      return result
    }
    .sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.document.updatedAt != $1.document.updatedAt {
        return $0.document.updatedAt > $1.document.updatedAt
      }
      return $0.chunk.ordinal < $1.chunk.ordinal
    }
    return searchDiversificationService.rank(fused, limit: limit)
  }

  private func invalidateSemanticBackfillCache() {
    semanticBackfillLock.lock()
    backfilledSemanticModelIDs.removeAll()
    semanticBackfillLock.unlock()
  }

  private func libraryHealthSynchronously() throws -> KnowledgeLibraryHealthSnapshot {
    let database = try database()
    let documents = try database.documents()
    let records = try database.semanticIndexRecords()
    var outdatedCount = 0
    var repairableCount = 0
    for document in documents {
      guard let revision = try database.currentRevision(documentID: document.id),
            revision.parserVersion < Self.parserVersion else { continue }
      outdatedCount += 1
      if document.kind == .webpage,
         let reference = revision.originalStorageReference?.nilIfEmpty,
         let fileURL = safeStorageFileURL(for: reference),
         fileManager.fileExists(atPath: fileURL.path) {
        repairableCount += 1
      }
    }

    let qualityService = KnowledgeChunkQualityService()
    let lowQualityCount = records.count {
      !qualityService.assessment(for: $0.chunk.content).isEligibleForRecommendation
    }
    var semanticRepairChunkIDs = Set<UUID>()
    for vector in semanticEmbeddingService.vectors(for: "资料库健康检查") {
      let needingRepair = try database.semanticIndexRecordsNeedingRepair(
        modelIdentifier: vector.modelIdentifier,
        expectedDimension: vector.values.count
      )
      semanticRepairChunkIDs.formUnion(needingRepair.map(\.chunk.id))
    }
    return KnowledgeLibraryHealthSnapshot(
      currentParserVersion: Self.parserVersion,
      documentCount: documents.count,
      indexedChunkCount: records.count,
      outdatedParserDocumentCount: outdatedCount,
      locallyRepairableDocumentCount: repairableCount,
      lowQualityChunkCount: lowQualityCount,
      semanticRepairChunkCount: semanticRepairChunkIDs.count
    )
  }

  private func makeLocalContentRepairPreviewsSynchronously(
    documentIDs: Set<UUID>?,
    includingCurrentParserVersion: Bool
  ) throws -> [KnowledgeSourceRefreshPreview] {
    let database = try database()
    let documents = try database.documents().filter { document in
      documentIDs?.contains(document.id) ?? true
    }
    var previews: [KnowledgeSourceRefreshPreview] = []
    for document in documents where document.kind == .webpage {
      try Task.checkCancellation()
      guard let revision = try database.currentRevision(documentID: document.id),
            includingCurrentParserVersion || revision.parserVersion < Self.parserVersion else { continue }
      guard let reference = revision.originalStorageReference?.nilIfEmpty,
            let fileURL = safeStorageFileURL(for: reference),
            let data = try? Data(contentsOf: fileURL) else {
        continue
      }
      var candidate = try candidate(
        data: data,
        sourceName: document.sourceName.nilIfEmpty ?? document.title,
        sourceURL: document.sourceURL,
        fileExtension: fileURL.pathExtension.nilIfEmpty ?? "html",
        preferredKind: .webpage,
        sourceModifiedAt: revision.sourceModifiedAt
      )
      candidate.existingDocumentID = document.id
      candidate.disposition = .update
      candidate.kind = document.kind
      candidate.title = document.title
      candidate.authors = document.authors
      candidate.language = document.language
      candidate.summary = document.summary
      candidate.tags = document.tags
      let previousText = try normalizedText(revisionID: revision.id)
      previews.append(KnowledgeSourceRefreshPreview(
        documentID: document.id,
        currentRevision: revision,
        importPreview: KnowledgeImportPreview(
          sourceName: document.sourceName,
          candidates: [candidate],
          warnings: ["将使用本机保存的原始网页归档重新净化，不会联网或覆盖旧版本。"]
        ),
        difference: revisionDifferenceService.difference(
          previousText: previousText,
          currentText: candidate.normalizedText
        )
      ))
    }
    return previews.sorted { lhs, rhs in
      lhs.currentRevision.importedAt < rhs.currentRevision.importedAt
    }
  }

  private func normalizedMetadataValues(
    _ values: [String],
    maximumCount: Int,
    maximumLength: Int
  ) -> [String] {
    var output: [String] = []
    for value in values {
      let normalized = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
      guard !normalized.isEmpty else { continue }
      let clipped = String(normalized.prefix(maximumLength))
      guard !output.contains(where: {
        $0.compare(clipped, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      }) else { continue }
      output.append(clipped)
      if output.count == maximumCount { break }
    }
    return output
  }

  private func storedByteCount(for revision: KnowledgeDocumentRevision) -> Int64? {
    [revision.originalStorageReference, revision.normalizedStorageReference]
      .compactMap { $0?.nilIfEmpty }
      .lazy
      .compactMap { reference -> Int64? in
        guard let fileURL = self.safeStorageFileURL(for: reference),
              let size = try? fileURL
          .resourceValues(forKeys: [.fileSizeKey])
          .fileSize,
          size > 0 else { return nil }
        return Int64(size)
      }
      .first
  }

  private func database() throws -> KnowledgeDatabase {
    databaseLock.lock()
    defer { databaseLock.unlock() }
    if let cachedDatabase { return cachedDatabase }
    let database = try KnowledgeDatabase(fileURL: rootURL.appendingPathComponent("library.sqlite"))
    cachedDatabase = database
    return database
  }

  private func makeImportPreviewSynchronously(
    sourceURL: URL,
    options: KnowledgeImportOptions
  ) throws -> KnowledgeImportPreview {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
      throw KnowledgeLibraryError.unreadableSource(sourceURL.path)
    }

    if isDirectory.boolValue {
      return try makeFolderPreview(sourceURL, options: options)
    }

    let candidate = try fileCandidate(sourceURL, options: options)
    return KnowledgeImportPreview(sourceName: sourceURL.lastPathComponent, candidates: [candidate])
  }

  private func makeImportPreviewSynchronously(
    sourceURLs: [URL],
    options: KnowledgeImportOptions
  ) throws -> KnowledgeImportPreview {
    var seenTopLevelPaths = Set<String>()
    let uniqueSourceURLs = sourceURLs.compactMap { sourceURL -> URL? in
      guard sourceURL.isFileURL else { return nil }
      let canonicalURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
      return seenTopLevelPaths.insert(canonicalURL.path).inserted ? canonicalURL : nil
    }

    guard !uniqueSourceURLs.isEmpty else {
      throw KnowledgeLibraryError.noImportableSources("请拖入本机文件或文件夹。")
    }
    guard uniqueSourceURLs.count <= 100 else {
      throw KnowledgeLibraryError.sourceLimitExceeded("一次最多拖入 100 个文件或文件夹，请分批导入。")
    }

    var candidates: [KnowledgeImportCandidate] = []
    var warnings: [String] = []
    var seenSourcePaths = Set<String>()
    var seenContentHashes = Set<String>()
    var totalOriginalBytes = 0

    for sourceURL in uniqueSourceURLs {
      try Task.checkCancellation()
      let preview: KnowledgeImportPreview
      do {
        preview = try makeImportPreviewSynchronously(
          sourceURL: sourceURL,
          options: options
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        warnings.append("\(sourceURL.lastPathComponent)：\(error.localizedDescription)")
        continue
      }

      warnings.append(contentsOf: preview.warnings)
      for candidate in preview.candidates {
        try Task.checkCancellation()
        let sourcePath = candidate.sourceURL?
          .standardizedFileURL
          .resolvingSymlinksInPath()
          .path
        let repeatsSource = sourcePath.map { !seenSourcePaths.insert($0).inserted } ?? false
        let repeatsContent = !seenContentHashes.insert(candidate.originalContentHash).inserted
        guard !repeatsSource, !repeatsContent else {
          warnings.append("跳过了重复拖入的资料：\(candidate.sourceName)")
          continue
        }

        totalOriginalBytes += candidate.originalData?.count ?? 0
        guard candidates.count < 500 else {
          throw KnowledgeLibraryError.sourceLimitExceeded("一次最多导入 500 个资料文件，请分批重试。")
        }
        guard totalOriginalBytes <= 100 * 1_024 * 1_024 else {
          throw KnowledgeLibraryError.sourceLimitExceeded("拖入资料总量超过 100 MB，请分批导入。")
        }
        candidates.append(candidate)
      }
    }

    guard !candidates.isEmpty else {
      throw KnowledgeLibraryError.noImportableSources(
        warnings.joined(separator: "；").nilIfEmpty ?? "没有找到支持的文件。"
      )
    }

    let sourceName = uniqueSourceURLs.count == 1
      ? uniqueSourceURLs[0].lastPathComponent
      : "\(uniqueSourceURLs.count) 个拖放项目"
    return KnowledgeImportPreview(
      sourceName: sourceName,
      candidates: candidates,
      warnings: warnings
    )
  }

  private func makeFolderPreview(
    _ directoryURL: URL,
    options: KnowledgeImportOptions
  ) throws -> KnowledgeImportPreview {
    let canonicalRoot = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
    guard let enumerator = fileManager.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      throw KnowledgeLibraryError.unreadableSource(directoryURL.path)
    }

    var candidates: [KnowledgeImportCandidate] = []
    var warnings: [String] = []
    var totalBytes = 0
    let supportedExtensions = Set(["md", "markdown", "mdx", "txt", "text", "html", "htm", "pdf", "epub"])

    for case let fileURL as URL in enumerator {
      try Task.checkCancellation()
      guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
      guard candidates.count < 500 else {
        throw KnowledgeLibraryError.sourceLimitExceeded("一次最多导入 500 个资料文件，请拆分文件夹后重试。")
      }

      let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
      let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
      guard canonicalFile.path.hasPrefix(rootPrefix) else {
        warnings.append("跳过了指向所选文件夹外部的符号链接：\(fileURL.lastPathComponent)")
        continue
      }

      let values = try canonicalFile.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { continue }
      let fileBytes = values.fileSize ?? 0
      totalBytes += fileBytes
      guard totalBytes <= 100 * 1_024 * 1_024 else {
        throw KnowledgeLibraryError.sourceLimitExceeded("文件夹资料总量超过 100 MB，请分批导入。")
      }

      do {
        candidates.append(try fileCandidate(canonicalFile, options: options))
      } catch let error as KnowledgeLibraryError {
        warnings.append(error.localizedDescription)
      }
    }

    return KnowledgeImportPreview(
      sourceName: directoryURL.lastPathComponent,
      candidates: candidates,
      warnings: warnings
    )
  }

  private func fileCandidate(
    _ sourceURL: URL,
    options: KnowledgeImportOptions
  ) throws -> KnowledgeImportCandidate {
    let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let fileSize = values.fileSize ?? 0
    guard fileSize <= 50 * 1_024 * 1_024 else {
      throw KnowledgeLibraryError.sourceLimitExceeded("文件超过 50 MB：\(sourceURL.lastPathComponent)")
    }
    guard let data = try? Data(contentsOf: sourceURL) else {
      throw KnowledgeLibraryError.unreadableSource(sourceURL.path)
    }
    return try candidate(
      data: data,
      sourceName: sourceURL.lastPathComponent,
      sourceURL: sourceURL.standardizedFileURL,
      fileExtension: sourceURL.pathExtension,
      preferredKind: nil,
      sourceModifiedAt: values.contentModificationDate,
      options: options
    )
  }

  private func candidate(
    data: Data,
    sourceName: String,
    sourceURL: URL?,
    fileExtension: String,
    preferredKind: KnowledgeDocumentKind?,
    sourceModifiedAt: Date?,
    options: KnowledgeImportOptions = KnowledgeImportOptions()
  ) throws -> KnowledgeImportCandidate {
    let lowerExtension = fileExtension.lowercased()
    let extraction: KnowledgeExtraction

    switch lowerExtension {
    case "md", "markdown", "mdx":
      extraction = try extractMarkdown(data: data, sourceName: sourceName)
    case "txt", "text":
      extraction = try extractPlainText(data: data, sourceName: sourceName)
    case "html", "htm":
      extraction = try extractHTML(data: data, sourceName: sourceName)
    case "pdf":
      extraction = try extractPDF(data: data, sourceName: sourceName, options: options)
    case "epub":
      extraction = try extractEPUB(data: data, sourceName: sourceName)
    default:
      if preferredKind == .webpage {
        extraction = try extractHTML(data: data, sourceName: sourceName)
      } else {
        throw KnowledgeLibraryError.unsupportedSource(sourceName)
      }
    }

    let normalizedText = normalizedText(from: extraction.sections)
    guard !normalizedText.isEmpty else {
      throw KnowledgeLibraryError.emptyContent(sourceName)
    }

    let originalHash = KnowledgeChunkingService.contentHash(for: data)
    let normalizedHash = KnowledgeChunkingService.contentHash(for: normalizedText)
    let existing = try database().existingDocument(
      sourceURL: sourceURL,
      originalHash: originalHash,
      normalizedHash: normalizedHash,
      parserVersion: Self.parserVersion
    )
    let disposition: KnowledgeImportDisposition
    if let existing {
      disposition = existing.identical ? .duplicate : .update
    } else {
      disposition = .new
    }

    return KnowledgeImportCandidate(
      existingDocumentID: existing?.document.id,
      disposition: disposition,
      kind: preferredKind ?? extraction.kind,
      title: extraction.title.nilIfEmpty ?? humanizedFilename(sourceName),
      authors: extraction.authors,
      language: extraction.language,
      summary: extraction.summary,
      tags: extraction.tags,
      sourceURL: sourceURL,
      sourceName: sourceName,
      sourceModifiedAt: sourceModifiedAt,
      originalFilenameExtension: lowerExtension.nilIfEmpty,
      originalData: data,
      originalContentHash: originalHash,
      normalizedText: normalizedText,
      normalizedContentHash: normalizedHash,
      sections: extraction.sections,
      warnings: extraction.warnings
    )
  }

  private func normalizedText(from sections: [KnowledgeExtractedSection]) -> String {
    KnowledgeChunkingService.normalizedText(
      sections.map { section in
        var parts: [String] = []
        if let heading = section.headingPath?.nilIfEmpty { parts.append("# \(heading)") }
        if let locator = section.locator?.nilIfEmpty { parts.append("[\(locator)]") }
        parts.append(section.text)
        return parts.joined(separator: "\n\n")
      }.joined(separator: "\n\n")
    )
  }

  private func makeBrowserImportPreviewSynchronously(
    _ capture: KnowledgeBrowserCapture
  ) throws -> KnowledgeImportPreview {
    guard capture.schemaVersion == KnowledgeBrowserCapture.currentSchemaVersion else {
      throw KnowledgeLibraryError.invalidBrowserCapture("不支持的数据版本 \(capture.schemaVersion)。")
    }
    guard var components = URLComponents(url: capture.sourceURL, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          components.host?.nilIfEmpty != nil,
          components.user == nil,
          components.password == nil else {
      throw KnowledgeLibraryError.invalidBrowserCapture("页面地址无效。")
    }
    components.fragment = nil
    guard let sourceURL = components.url else {
      throw KnowledgeLibraryError.invalidBrowserCapture("页面地址无效。")
    }

    guard capture.contentText.utf8.count <= 5 * 1_024 * 1_024 else {
      throw KnowledgeLibraryError.sourceLimitExceeded("浏览器提取的正文超过 5 MB。")
    }
    if let archiveData = capture.archiveData,
       archiveData.count > 24 * 1_024 * 1_024 {
      throw KnowledgeLibraryError.sourceLimitExceeded("完整页面归档超过 24 MB，请关闭大型媒体后重试。")
    }
    if let originalHTML = capture.originalHTML,
       originalHTML.utf8.count > 6 * 1_024 * 1_024 {
      throw KnowledgeLibraryError.sourceLimitExceeded("页面 HTML 超过 6 MB。")
    }

    let sanitizedHTML = capture.originalHTML?.nilIfEmpty.map {
      webContentSanitizer.sanitize(html: $0)
    }
    let title = capture.title.trimmedForPublishing.nilIfEmpty
      ?? sanitizedHTML?.title
      ?? sourceURL.host
      ?? "浏览器保存的页面"
    var sections = sanitizedHTML?.sections ?? []
    if sections.isEmpty {
      sections = webContentSanitizer.sanitizeExtractedText(capture.contentText)
    }
    sections = sections.map { section in
      KnowledgeExtractedSection(
        headingPath: section.headingPath?.nilIfEmpty ?? title,
        locator: section.locator?.nilIfEmpty ?? sourceURL.absoluteString,
        text: section.text
      )
    }
    let normalizedText = normalizedText(from: sections)
    guard !normalizedText.isEmpty else {
      throw KnowledgeLibraryError.invalidBrowserCapture("没有提取到可检索正文。")
    }

    let archiveFormat = capture.archiveFormat?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let originalData: Data
    let originalExtension: String
    if let archiveData = capture.archiveData {
      guard archiveFormat == "mhtml" || archiveFormat == "html" else {
        throw KnowledgeLibraryError.invalidBrowserCapture("页面归档格式无效。")
      }
      originalData = archiveData
      originalExtension = archiveFormat ?? "mhtml"
    } else if let originalHTML = capture.originalHTML?.nilIfEmpty {
      originalData = Data(originalHTML.utf8)
      originalExtension = "html"
    } else {
      originalData = Data(capture.contentText.utf8)
      originalExtension = "txt"
    }

    let originalHash = KnowledgeChunkingService.contentHash(for: originalData)
    let normalizedHash = KnowledgeChunkingService.contentHash(for: normalizedText)
    let existing = try database().existingDocument(
      sourceURL: sourceURL,
      originalHash: originalHash,
      normalizedHash: normalizedHash,
      parserVersion: Self.parserVersion
    )
    let disposition: KnowledgeImportDisposition
    if let existing {
      disposition = existing.identical ? .duplicate : .update
    } else {
      disposition = .new
    }
    var warnings = ["页面由浏览器插件在 \(capture.capturedAt.formatted(date: .abbreviated, time: .shortened)) 保存；正文和归档均留在本机。"]
    if let sanitizedHTML {
      warnings.append("保存前已在本机重新净化网页正文，原始页面归档保持不变。")
      if sanitizedHTML.removedNoiseBlockCount > 0 {
        warnings.append("已移除 \(sanitizedHTML.removedNoiseBlockCount) 个导航、广告或交互噪声区块。")
      }
    }
    let candidate = KnowledgeImportCandidate(
      existingDocumentID: existing?.document.id,
      disposition: disposition,
      kind: .webpage,
      title: title,
      authors: {
        let captured = capture.authors.map(\.trimmedForPublishing).filter { !$0.isEmpty }
        return captured.isEmpty ? (sanitizedHTML?.authors ?? []) : captured
      }(),
      language: capture.language?.trimmedForPublishing.nilIfEmpty ?? sanitizedHTML?.language,
      summary: capture.summary.trimmedForPublishing.nilIfEmpty ?? sanitizedHTML?.summary ?? "",
      tags: capture.tags.map(\.trimmedForPublishing).filter { !$0.isEmpty },
      sourceURL: sourceURL,
      sourceName: sourceURL.host ?? sourceURL.absoluteString,
      sourceModifiedAt: nil,
      originalFilenameExtension: originalExtension,
      originalData: originalData,
      originalContentHash: originalHash,
      normalizedText: normalizedText,
      normalizedContentHash: normalizedHash,
      sections: sections,
      warnings: warnings
    )
    return KnowledgeImportPreview(sourceName: sourceURL.absoluteString, candidates: [candidate])
  }

  private func commitSynchronously(
    _ preview: KnowledgeImportPreview,
    destination: KnowledgeImportDestination
  ) throws -> KnowledgeImportResult {
    storageMutationLock.lock()
    defer { storageMutationLock.unlock() }
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let database = try database()
    if case .folder(let folderID) = destination,
       try !database.folders().contains(where: { $0.id == folderID }) {
      throw KnowledgeLibraryError.missingFolder
    }
    var insertedCount = 0
    var updatedCount = 0
    var skippedCount = 0

    for candidate in preview.candidates {
      try Task.checkCancellation()
      guard candidate.disposition != .duplicate else {
        // A duplicate import is also a cheap integrity opportunity. Rewriting
        // only when bytes differ repairs truncated or externally damaged
        // content-addressed files without creating a redundant revision.
        _ = try persistOriginalData(candidate)
        _ = try persistNormalizedText(candidate)
        if let documentID = candidate.existingDocumentID {
          switch destination {
          case .preserveExisting:
            break
          case .unfiled:
            try database.setFolder(nil, documentID: documentID)
          case .folder(let folderID):
            try database.setFolder(folderID, documentID: documentID)
          }
        }
        skippedCount += 1
        continue
      }

      let existingDocument = try candidate.existingDocumentID.flatMap { try database.document(id: $0) }
      let documentID = existingDocument?.id ?? UUID()
      let revisionID = UUID()
      let now = Date()
      let originalReference = try persistOriginalData(candidate)
      let normalizedReference = try persistNormalizedText(candidate)

      let document = KnowledgeDocument(
        id: documentID,
        kind: candidate.kind,
        title: candidate.title,
        authors: candidate.authors,
        language: candidate.language,
        summary: candidate.summary,
        tags: candidate.tags,
        sourceURL: candidate.sourceURL,
        sourceName: candidate.sourceName,
        folderID: {
          switch destination {
          case .preserveExisting: existingDocument?.folderID
          case .unfiled: nil
          case .folder(let folderID): folderID
          }
        }(),
        sourceByteCount: Int64(candidate.originalData?.count ?? candidate.normalizedText.utf8.count),
        allowsAIUse: existingDocument?.allowsAIUse ?? true,
        isArchived: existingDocument?.isArchived ?? false,
        importedAt: existingDocument?.importedAt ?? now,
        updatedAt: now,
        currentRevisionID: revisionID
      )
      let revision = KnowledgeDocumentRevision(
        id: revisionID,
        documentID: documentID,
        originalContentHash: candidate.originalContentHash,
        normalizedContentHash: candidate.normalizedContentHash,
        parserVersion: Self.parserVersion,
        importedAt: now,
        sourceModifiedAt: candidate.sourceModifiedAt,
        originalStorageReference: originalReference,
        normalizedStorageReference: normalizedReference
      )
      let chunks = chunkingService.chunks(
        documentID: documentID,
        revisionID: revisionID,
        sections: candidate.sections
      )
      guard !chunks.isEmpty else {
        throw KnowledgeLibraryError.emptyContent(candidate.sourceName)
      }

      let embeddings = chunks.flatMap { chunk in
        let record = KnowledgeSemanticIndexRecord(document: document, chunk: chunk)
        return semanticEmbeddingService.vectors(for: record.searchableText).map { vector in
          KnowledgeChunkEmbedding(
            chunkID: chunk.id,
            revisionID: chunk.revisionID,
            vector: vector
          )
        }
      }

      try database.commit(
        document: document,
        revision: revision,
        chunks: chunks,
        embeddings: embeddings
      )
      if candidate.disposition == .update {
        updatedCount += 1
      } else {
        insertedCount += 1
      }
    }

    return KnowledgeImportResult(
      insertedCount: insertedCount,
      updatedCount: updatedCount,
      skippedCount: skippedCount
    )
  }

  private func persistOriginalData(_ candidate: KnowledgeImportCandidate) throws -> String? {
    guard let data = candidate.originalData else { return nil }
    let suffix = candidate.originalFilenameExtension?.nilIfEmpty.map { ".\($0)" } ?? ""
    let reference = "blobs/sha256/\(String(candidate.originalContentHash.prefix(2)))/\(candidate.originalContentHash)\(suffix)"
    try persist(data, reference: reference)
    return reference
  }

  private func persistNormalizedText(_ candidate: KnowledgeImportCandidate) throws -> String {
    let reference = "normalized/sha256/\(String(candidate.normalizedContentHash.prefix(2)))/\(candidate.normalizedContentHash).md"
    try persist(Data(candidate.normalizedText.utf8), reference: reference)
    return reference
  }

  private func persist(_ data: Data, reference: String) throws {
    let destination = rootURL.appendingPathComponent(reference)
    if fileManager.fileExists(atPath: destination.path),
       (try? Data(contentsOf: destination, options: .mappedIfSafe)) == data {
      return
    }
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination, options: .atomic)
  }

  private func extractMarkdown(data: Data, sourceName: String) throws -> KnowledgeExtraction {
    guard let source = String(data: data, encoding: .utf8) else {
      throw KnowledgeLibraryError.unreadableSource(sourceName)
    }
    let parsed = markdownFrontMatter(source)
    let title = parsed.values["title"]?.nilIfEmpty
      ?? firstMarkdownHeading(parsed.body)
      ?? humanizedFilename(sourceName)
    let authors = listValue(parsed.values["authors"] ?? parsed.values["author"])
    let tags = listValue(parsed.values["tags"] ?? parsed.values["tag"])
    let summary = parsed.values["summary"] ?? parsed.values["description"] ?? ""
    return KnowledgeExtraction(
      kind: .markdown,
      title: title,
      authors: authors,
      language: parsed.values["language"] ?? parsed.values["lang"],
      summary: summary,
      tags: tags,
      sections: markdownSections(parsed.body),
      warnings: []
    )
  }

  private func extractPlainText(data: Data, sourceName: String) throws -> KnowledgeExtraction {
    guard let text = String(data: data, encoding: .utf8) else {
      throw KnowledgeLibraryError.unreadableSource(sourceName)
    }
    return KnowledgeExtraction(
      kind: .text,
      title: firstNonEmptyLine(text) ?? humanizedFilename(sourceName),
      authors: [],
      language: nil,
      summary: "",
      tags: [],
      sections: [KnowledgeExtractedSection(text: text)],
      warnings: []
    )
  }

  private func extractHTML(data: Data, sourceName: String) throws -> KnowledgeExtraction {
    let sanitized = try webContentSanitizer.sanitize(data: data, sourceName: sourceName)
    var warnings = ["网页正文已在本机净化；原始 HTML 保持不变。"]
    if sanitized.selectedMainContent {
      warnings.append("已优先提取页面的 article/main 正文区域。")
    }
    if sanitized.removedNoiseBlockCount > 0 {
      warnings.append("已移除 \(sanitized.removedNoiseBlockCount) 个导航、广告或交互噪声区块。")
    }
    return KnowledgeExtraction(
      kind: .webpage,
      title: sanitized.title ?? humanizedFilename(sourceName),
      authors: sanitized.authors,
      language: sanitized.language,
      summary: sanitized.summary,
      tags: [],
      sections: sanitized.sections,
      warnings: warnings
    )
  }

  private func extractPDF(
    data: Data,
    sourceName: String,
    options: KnowledgeImportOptions
  ) throws -> KnowledgeExtraction {
    guard let document = PDFDocument(data: data) else {
      throw KnowledgeLibraryError.unreadableSource(sourceName)
    }
    var sections: [KnowledgeExtractedSection] = []
    var emptyPageCount = 0
    var ocrAttemptCount = 0
    var ocrRecognizedCount = 0
    var ocrFailureCount = 0
    var ocrLimitSkippedCount = 0
    for index in 0..<document.pageCount {
      try Task.checkCancellation()
      guard let page = document.page(at: index) else {
        emptyPageCount += 1
        continue
      }
      let pageText = page.string?.trimmedForPublishing ?? ""
      if !pageText.isEmpty {
        sections.append(KnowledgeExtractedSection(locator: "第 \(index + 1) 页", text: pageText))
        continue
      }

      guard options.performsPDFOCR else {
        emptyPageCount += 1
        continue
      }
      guard ocrAttemptCount < options.maximumPDFOCRPageCount else {
        emptyPageCount += 1
        ocrLimitSkippedCount += 1
        continue
      }

      ocrAttemptCount += 1
      do {
        let recognizedText = try pdfOCRService.recognizeText(in: page).trimmedForPublishing
        if recognizedText.isEmpty {
          emptyPageCount += 1
        } else {
          ocrRecognizedCount += 1
          sections.append(KnowledgeExtractedSection(
            locator: "第 \(index + 1) 页（OCR）",
            text: recognizedText
          ))
        }
      } catch {
        emptyPageCount += 1
        ocrFailureCount += 1
      }
    }
    var warnings: [String] = []
    if ocrRecognizedCount > 0 {
      warnings.append("已在本机使用 Vision OCR 识别 \(ocrRecognizedCount) 页；原始 PDF 保持不变。")
    }
    if ocrFailureCount > 0 {
      warnings.append("有 \(ocrFailureCount) 页 OCR 处理失败，未加入检索文本。")
    }
    if ocrLimitSkippedCount > 0 {
      warnings.append("OCR 最多处理 \(options.maximumPDFOCRPageCount) 页；另有 \(ocrLimitSkippedCount) 个无文字层页面未识别。")
    }
    if emptyPageCount > 0 {
      let reason = options.performsPDFOCR ? "OCR 后仍没有可识别文字" : "未启用 OCR"
      warnings.append("有 \(emptyPageCount) 页\(reason)，这些页面暂时不能检索。")
    }
    let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfEmpty
      ?? humanizedFilename(sourceName)
    let author = (document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)?.nilIfEmpty
    return KnowledgeExtraction(
      kind: .pdf,
      title: title,
      authors: author.map { [$0] } ?? [],
      language: nil,
      summary: "",
      tags: [],
      sections: sections,
      warnings: warnings
    )
  }

  private func extractEPUB(data: Data, sourceName: String) throws -> KnowledgeExtraction {
    let book = try epubParser.parse(data: data, sourceName: sourceName)
    return KnowledgeExtraction(
      kind: .book,
      title: book.title.nilIfEmpty ?? humanizedFilename(sourceName),
      authors: book.authors,
      language: book.language,
      summary: book.summary,
      tags: book.tags,
      sections: book.sections,
      warnings: book.warnings
    )
  }

  private func markdownFrontMatter(_ source: String) -> (values: [String: String], body: String) {
    let lines = source.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return ([:], source)
    }
    guard let end = lines.dropFirst().firstIndex(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }) else {
      return ([:], source)
    }
    var values: [String: String] = [:]
    for line in lines[1..<end] {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      values[key] = value
    }
    return (values, lines[(end + 1)...].joined(separator: "\n"))
  }

  private func markdownSections(_ source: String) -> [KnowledgeExtractedSection] {
    var sections: [KnowledgeExtractedSection] = []
    var headings: [Int: String] = [:]
    var buffer: [String] = []

    func flush() {
      let text = buffer.joined(separator: "\n").trimmedForPublishing
      buffer = []
      guard !text.isEmpty else { return }
      let path = headings.keys.sorted().compactMap { headings[$0] }.joined(separator: " › ")
      sections.append(KnowledgeExtractedSection(
        headingPath: path.nilIfEmpty,
        text: text
      ))
    }

    for line in source.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let hashes = trimmed.prefix { $0 == "#" }.count
      if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
        flush()
        let heading = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        headings[hashes] = heading
        if hashes < 6 {
          for level in (hashes + 1)...6 { headings.removeValue(forKey: level) }
        }
      } else {
        buffer.append(line)
      }
    }
    flush()
    if sections.isEmpty {
      return [KnowledgeExtractedSection(text: source)]
    }
    return sections
  }

  private func firstMarkdownHeading(_ source: String) -> String? {
    source.components(separatedBy: .newlines).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("# ") else { return nil }
      return String(trimmed.dropFirst(2)).trimmedForPublishing.nilIfEmpty
    }.first
  }

  private func listValue(_ value: String?) -> [String] {
    guard let value else { return [] }
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return trimmed
      .components(separatedBy: CharacterSet(charactersIn: ",，"))
      .map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      }
      .filter { !$0.isEmpty }
  }

  private func firstCapture(in text: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
          ),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range]).trimmedForPublishing.nilIfEmpty
  }

  private func firstNonEmptyLine(_ text: String) -> String? {
    text.components(separatedBy: .newlines)
      .map { $0.trimmedForPublishing }
      .first(where: { !$0.isEmpty })?
      .nilIfEmpty
  }

  private func humanizedFilename(_ name: String) -> String {
    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    let humanized = stem
      .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return humanized.nilIfEmpty ?? "未命名资料"
  }

  private func decodeHTMLEntities(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
  }

  private func clipped(_ text: String, maximumCharacters: Int) -> String {
    guard text.count > maximumCharacters else { return text }
    let end = text.index(text.startIndex, offsetBy: maximumCharacters)
    return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}

private struct KnowledgeExtraction {
  var kind: KnowledgeDocumentKind
  var title: String
  var authors: [String]
  var language: String?
  var summary: String
  var tags: [String]
  var sections: [KnowledgeExtractedSection]
  var warnings: [String]
}
