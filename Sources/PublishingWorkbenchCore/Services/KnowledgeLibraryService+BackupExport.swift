import Foundation

extension KnowledgeLibraryService {
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

  func safeStorageFileURL(for reference: String) -> URL? {
    let components = reference.split(separator: "/", omittingEmptySubsequences: false)
    guard !reference.hasPrefix("/"),
          !reference.contains("\\"),
          components.count >= 2,
          components.first == "blobs"
            || components.first == "captured"
            || components.first == "normalized",
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

  func exportDocumentsSynchronously(
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

  func safeExportFilename(_ title: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
      .union(.controlCharacters)
    let sanitized = title
      .components(separatedBy: forbidden)
      .joined(separator: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return String((sanitized.nilIfEmpty ?? "未命名资料").prefix(100))
  }

  func jsonEncoded<T: Encodable>(_ value: T) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}
