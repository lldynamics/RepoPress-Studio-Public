import Foundation
import PublishingKnowledgeCore

extension KnowledgeLibraryService {
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

  func libraryHealthSynchronously() throws -> KnowledgeLibraryHealthSnapshot {
    let database = try database()
    let documents = try database.documents()
    let records = try database.semanticIndexRecords()
    var outdatedCount = 0
    var repairableCount = 0
    for document in documents where document.kind == .webpage {
      guard let revision = try database.currentRevision(documentID: document.id),
            revision.parserVersion < Self.parserVersion else { continue }
      outdatedCount += 1
      if let reference = revision.originalStorageReference?.nilIfEmpty,
         let fileURL = safeStorageFileURL(for: reference),
         fileManager.fileExists(atPath: fileURL.path) {
        repairableCount += 1
      }
    }

    let qualityService = KnowledgeChunkQualityService()
    let lowQualityCount = records.count {
      !qualityService.assessment(for: $0.chunk.content).isEligibleForRecommendation
    }
    try Task.checkCancellation()
    let availableModelDimensions = semanticEmbeddingService.availableModelDimensions(
      for: records.map(\.searchableText)
    )
    try Task.checkCancellation()
    let storedChunkIDsByModel = try database.semanticEmbeddingChunkIDsByModelIdentifier()
    var semanticRepairChunkIDs = Set<UUID>()
    for (modelIdentifier, expectedDimension) in availableModelDimensions {
      let needingRepair = try database.semanticIndexRecordsNeedingRepair(
        modelIdentifier: modelIdentifier,
        expectedDimension: expectedDimension
      )
      semanticRepairChunkIDs.formUnion(needingRepair.map(\.chunk.id))
    }
    for (modelIdentifier, chunkIDs) in storedChunkIDsByModel
      where availableModelDimensions[modelIdentifier] == nil {
      semanticRepairChunkIDs.formUnion(chunkIDs)
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

  func makeLocalContentRepairPreviewsSynchronously(
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
            let data = try? BoundedFileReader.data(
              at: fileURL,
              maximumByteCount: WorkbenchContentFileReadLimits.binaryDocumentByteCount
            ) else {
        continue
      }
      let sourceExtension = fileURL.pathExtension.nilIfEmpty ?? "html"
      var candidate = try candidate(
        data: data,
        sourceName: document.sourceName.nilIfEmpty ?? document.title,
        sourceURL: document.sourceURL,
        fileExtension: sourceExtension,
        preferredKind: .webpage,
        sourceModifiedAt: revision.sourceModifiedAt
      )
      if ["txt", "text"].contains(sourceExtension.lowercased()),
         let capturedText = String(data: data, encoding: .utf8) {
        let sanitizedSections = webContentSanitizer.sanitizeExtractedText(capturedText).map { section in
          KnowledgeExtractedSection(
            headingPath: section.headingPath?.nilIfEmpty ?? document.title,
            locator: section.locator?.nilIfEmpty ?? document.sourceURL?.absoluteString,
            text: section.text
          )
        }
        let sanitizedText = normalizedText(from: sanitizedSections)
        guard !sanitizedText.isEmpty else { continue }
        candidate.normalizedText = sanitizedText
        candidate.normalizedContentHash = KnowledgeChunkingService.contentHash(for: sanitizedText)
        candidate.sections = sanitizedSections
      }
      candidate.existingDocumentID = document.id
      candidate.disposition = .update
      candidate.kind = document.kind
      candidate.title = document.title
      candidate.authors = document.authors
      candidate.language = document.language
      candidate.summary = document.summary
      candidate.tags = document.tags
      candidate.capturedText = try capturedText(documentID: document.id)
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

  func normalizedMetadataValues(
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

  func storedByteCount(for revision: KnowledgeDocumentRevision) -> Int64? {
    [
      revision.originalStorageReference,
      revision.capturedTextStorageReference,
      revision.normalizedStorageReference,
    ]
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

  public func maintainDatabase() async throws {
    let service = self
    try await Task.detached(priority: .utility) {
      let database = try service.database()
      try database.checkpointWAL(mode: .passive)
      try database.optimizeDatabase()
    }.value
  }
}
