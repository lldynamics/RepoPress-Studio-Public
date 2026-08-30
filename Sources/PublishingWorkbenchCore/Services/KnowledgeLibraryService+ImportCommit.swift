import Foundation

extension KnowledgeLibraryService {
  public func commit(
    _ preview: KnowledgeImportPreview,
    destination: KnowledgeImportDestination = .preserveExisting
  ) async throws -> KnowledgeImportResult {
    try Task.checkCancellation()
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try service.commitSynchronously(preview, destination: destination)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func commitSynchronously(
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
    var documentIDs: [UUID] = []
    var records: [KnowledgeDatabaseImportRecord] = []
    var capturedTextAssignments: [KnowledgeDatabaseCapturedTextAssignment] = []
    var folderAssignments: [KnowledgeDatabaseFolderAssignment] = []
    var storageArtifacts: [String: Data] = [:]

    func registerStorageArtifact(reference: String?, data: Data?) throws {
      guard let reference, let data else { return }
      if let existingData = storageArtifacts[reference] {
        guard existingData == data else {
          throw KnowledgeLibraryError.database("内容地址冲突：\(reference)")
        }
        return
      }
      storageArtifacts[reference] = data
    }

    for candidate in preview.candidates {
      try Task.checkCancellation()
      guard candidate.disposition != .duplicate else {
        // A duplicate import is also a cheap integrity opportunity. Rewriting
        // only when bytes differ repairs truncated or externally damaged
        // content-addressed files without creating a redundant revision.
        try registerStorageArtifact(
          reference: originalStorageReference(for: candidate),
          data: candidate.originalData
        )
        try registerStorageArtifact(
          reference: normalizedStorageReference(for: candidate),
          data: Data(candidate.normalizedText.utf8)
        )
        if let documentID = candidate.existingDocumentID {
          if let revision = try database.currentRevision(documentID: documentID) {
            if let existingReference = revision.capturedTextStorageReference?.nilIfEmpty {
              if existingReference == capturedTextStorageReference(for: candidate) {
                try registerStorageArtifact(
                  reference: existingReference,
                  data: candidate.capturedText?.nilIfEmpty.map { Data($0.utf8) }
                )
              }
            } else if let capturedReference = capturedTextStorageReference(for: candidate),
                      let capturedText = candidate.capturedText?.nilIfEmpty {
              try registerStorageArtifact(
                reference: capturedReference,
                data: Data(capturedText.utf8)
              )
              capturedTextAssignments.append(
                KnowledgeDatabaseCapturedTextAssignment(
                  revisionID: revision.id,
                  storageReference: capturedReference
                )
              )
            }
          }
          if !documentIDs.contains(documentID) {
            documentIDs.append(documentID)
          }
          switch destination {
          case .preserveExisting:
            break
          case .unfiled:
            folderAssignments.append(
              KnowledgeDatabaseFolderAssignment(documentID: documentID, folderID: nil)
            )
          case .folder(let folderID):
            folderAssignments.append(
              KnowledgeDatabaseFolderAssignment(documentID: documentID, folderID: folderID)
            )
          }
        }
        skippedCount += 1
        continue
      }

      let existingDocument = try candidate.existingDocumentID.flatMap { try database.document(id: $0) }
      let documentID = existingDocument?.id ?? UUID()
      if !documentIDs.contains(documentID) {
        documentIDs.append(documentID)
      }
      let revisionID = UUID()
      let now = Date()
      let originalReference = originalStorageReference(for: candidate)
      let capturedTextReference = capturedTextStorageReference(for: candidate)
      let normalizedReference = normalizedStorageReference(for: candidate)
      try registerStorageArtifact(reference: originalReference, data: candidate.originalData)
      try registerStorageArtifact(
        reference: capturedTextReference,
        data: candidate.capturedText?.nilIfEmpty.map { Data($0.utf8) }
      )
      try registerStorageArtifact(
        reference: normalizedReference,
        data: Data(candidate.normalizedText.utf8)
      )

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
        allowsLocalSemanticIndex: candidate.allowsLocalSemanticIndex
          ?? existingDocument?.allowsLocalSemanticIndex
          ?? true,
        allowsRemoteAIUse: candidate.allowsRemoteAIUse
          ?? existingDocument?.allowsRemoteAIUse
          ?? false,
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
        capturedTextStorageReference: capturedTextReference,
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

      let embeddings =
        document.allowsLocalSemanticIndex
        ? chunks.flatMap { chunk in
          let record = KnowledgeSemanticIndexRecord(document: document, chunk: chunk)
          return semanticEmbeddingService.vectors(
            for: record.searchableText,
            role: .passage
          ).map { vector in
            KnowledgeChunkEmbedding(
              chunkID: chunk.id,
              revisionID: chunk.revisionID,
              vector: vector,
              inputHash: record.searchableTextHash
            )
          }
        } : []

      records.append(
        KnowledgeDatabaseImportRecord(
          document: document,
          revision: revision,
          chunks: chunks,
          embeddings: embeddings
        )
      )
      if candidate.disposition == .update {
        updatedCount += 1
      } else {
        insertedCount += 1
      }
    }

    let stagingRootURL = rootURL.appendingPathComponent(
      ".import-staging-\(UUID().uuidString)",
      isDirectory: true
    )
    var installedArtifacts: [KnowledgeImportInstalledArtifact] = []
    defer { try? fileManager.removeItem(at: stagingRootURL) }

    do {
      try stageImportArtifacts(storageArtifacts, at: stagingRootURL)
      installedArtifacts = try installImportArtifacts(
        storageArtifacts,
        from: stagingRootURL
      )
      try Task.checkCancellation()
      try database.commitImportBatch(
        records: records,
        capturedTextAssignments: capturedTextAssignments,
        folderAssignments: folderAssignments
      )
    } catch {
      try throwAfterRollingBackImportArtifacts(
        installedArtifacts,
        primaryError: error
      )
    }

    return KnowledgeImportResult(
      insertedCount: insertedCount,
      updatedCount: updatedCount,
      skippedCount: skippedCount,
      documentIDs: documentIDs
    )
  }

  func originalStorageReference(for candidate: KnowledgeImportCandidate) -> String? {
    guard candidate.originalData != nil else { return nil }
    let suffix = candidate.originalFilenameExtension?.nilIfEmpty.map { ".\($0)" } ?? ""
    return "blobs/sha256/\(String(candidate.originalContentHash.prefix(2)))/\(candidate.originalContentHash)\(suffix)"
  }

  func normalizedStorageReference(for candidate: KnowledgeImportCandidate) -> String {
    "normalized/sha256/\(String(candidate.normalizedContentHash.prefix(2)))/\(candidate.normalizedContentHash).md"
  }

  func capturedTextStorageReference(
    for candidate: KnowledgeImportCandidate
  ) -> String? {
    guard let capturedText = candidate.capturedText?.nilIfEmpty else { return nil }
    let hash = KnowledgeChunkingService.contentHash(for: capturedText)
    return "captured/sha256/\(String(hash.prefix(2)))/\(hash).txt"
  }

  func stageImportArtifacts(
    _ artifacts: [String: Data],
    at stagingRootURL: URL
  ) throws {
    for reference in artifacts.keys.sorted() {
      try Task.checkCancellation()
      guard safeStorageFileURL(for: reference) != nil,
            let data = artifacts[reference] else {
        throw KnowledgeLibraryError.database("非法的内容存储路径：\(reference)")
      }
      let stagedURL = stagingRootURL.appendingPathComponent(reference)
      try fileManager.createDirectory(
        at: stagedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: stagedURL, options: .atomic)
    }
  }

  func installImportArtifacts(
    _ artifacts: [String: Data],
    from stagingRootURL: URL
  ) throws -> [KnowledgeImportInstalledArtifact] {
    var installed: [KnowledgeImportInstalledArtifact] = []
    do {
      for reference in artifacts.keys.sorted() {
        try Task.checkCancellation()
        guard let data = artifacts[reference],
              let destinationURL = safeStorageFileURL(for: reference) else {
          throw KnowledgeLibraryError.database("非法的内容存储路径：\(reference)")
        }
        if fileManager.fileExists(atPath: destinationURL.path),
           (try? BoundedFileReader.data(
             at: destinationURL,
             maximumByteCount: WorkbenchContentFileReadLimits.binaryDocumentByteCount
           )) == data {
          continue
        }

        try fileManager.createDirectory(
          at: destinationURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
          let backupURL = stagingRootURL
            .appendingPathComponent("rollback", isDirectory: true)
            .appendingPathComponent(reference)
          try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try fileManager.moveItem(at: destinationURL, to: backupURL)
          installed.append(
            .replaced(destinationURL: destinationURL, backupURL: backupURL)
          )
        } else {
          installed.append(.created(destinationURL: destinationURL))
        }

        let stagedURL = stagingRootURL.appendingPathComponent(reference)
        try fileManager.moveItem(at: stagedURL, to: destinationURL)
      }
      return installed
    } catch {
      try throwAfterRollingBackImportArtifacts(
        installed,
        primaryError: error
      )
    }
  }

  func throwAfterRollingBackImportArtifacts(
    _ installed: [KnowledgeImportInstalledArtifact],
    primaryError: Error
  ) throws -> Never {
    do {
      try rollbackImportArtifacts(installed)
    } catch let rollbackError {
      throw KnowledgeLibraryError.database(
        "导入失败：\(primaryError.localizedDescription)；自动回滚也失败：\(rollbackError.localizedDescription)"
      )
    }
    throw primaryError
  }

  func rollbackImportArtifacts(
    _ installed: [KnowledgeImportInstalledArtifact]
  ) throws {
    var rollbackFailures: [String] = []
    for artifact in installed.reversed() {
      do {
        switch artifact {
        case .created(let destinationURL):
          if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
          }
        case .replaced(let destinationURL, let backupURL):
          if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
          }
          guard fileManager.fileExists(atPath: backupURL.path) else {
            throw KnowledgeLibraryError.database(
              "回滚副本缺失：\(backupURL.lastPathComponent)"
            )
          }
          try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try fileManager.moveItem(at: backupURL, to: destinationURL)
        }
      } catch {
        rollbackFailures.append(error.localizedDescription)
      }
    }
    guard rollbackFailures.isEmpty else {
      throw KnowledgeLibraryError.database(
        rollbackFailures.joined(separator: "；")
      )
    }
  }

  func clipped(_ text: String, maximumCharacters: Int) -> String {
    guard text.count > maximumCharacters else { return text }
    let end = text.index(text.startIndex, offsetBy: maximumCharacters)
    return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}
