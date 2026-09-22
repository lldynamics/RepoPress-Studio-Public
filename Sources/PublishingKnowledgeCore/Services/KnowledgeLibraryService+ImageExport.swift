import Foundation
import PublishingCoreSupport

private let knowledgeImageExportMaximumByteCount = 25 * 1_024 * 1_024

extension KnowledgeLibraryService {
  /// Exports selected managed image originals without changing library files.
  /// The completion callback is invoked on the detached IO executor.
  public func exportImages(
    documentIDs: Set<UUID>,
    to destinationDirectory: URL,
    mode: KnowledgeImageExportMode,
    progress: @escaping @Sendable (_ completedCount: Int, _ totalCount: Int) -> Void = { _, _ in }
  ) async throws -> KnowledgeImageExportReport {
    let service = self
    return try await performKnowledgeLibraryIO(priority: .userInitiated) {
      try service.exportImagesSynchronously(
        documentIDs: documentIDs,
        to: destinationDirectory,
        mode: mode,
        progress: progress
      )
    }
  }

  func exportImagesSynchronously(
    documentIDs: Set<UUID>,
    to destinationDirectory: URL,
    mode: KnowledgeImageExportMode,
    progress: @escaping @Sendable (_ completedCount: Int, _ totalCount: Int) -> Void
  ) throws -> KnowledgeImageExportReport {
    let resolvedDestination = try validatedImageExportDestination(destinationDirectory)
    let orderedIDs = documentIDs.sorted { $0.uuidString < $1.uuidString }
    progress(0, orderedIDs.count)
    guard !orderedIDs.isEmpty else {
      return KnowledgeImageExportReport(
        destinationDirectory: resolvedDestination,
        mode: mode,
        items: []
      )
    }

    storageMutationLock.lock()
    defer { storageMutationLock.unlock() }
    let documentsByID = Dictionary(
      uniqueKeysWithValues: try database().documents().map { ($0.id, $0) })
    var results: [KnowledgeImageExportItemResult] = []
    results.reserveCapacity(orderedIDs.count)

    for (index, documentID) in orderedIDs.enumerated() {
      try Task.checkCancellation()
      let result: KnowledgeImageExportItemResult
      guard let document = documentsByID[documentID] else {
        result = KnowledgeImageExportItemResult(
          documentID: documentID,
          sourceName: CoreL10n.text("未知资料"),
          outcome: .failed(reason: CoreL10n.text("所选资料已不存在。"))
        )
        results.append(result)
        progress(index + 1, orderedIDs.count)
        continue
      }
      guard document.kind == .image else {
        result = KnowledgeImageExportItemResult(
          documentID: documentID,
          sourceName: document.sourceName,
          outcome: .skipped(reason: CoreL10n.text("不是图片资料。"))
        )
        results.append(result)
        progress(index + 1, orderedIDs.count)
        continue
      }

      result = exportImage(
        document: document,
        destinationDirectory: resolvedDestination,
        mode: mode
      )
      results.append(result)
      progress(index + 1, orderedIDs.count)
    }

    return KnowledgeImageExportReport(
      destinationDirectory: resolvedDestination,
      mode: mode,
      items: results
    )
  }

  private func exportImage(
    document: KnowledgeDocument,
    destinationDirectory: URL,
    mode: KnowledgeImageExportMode
  ) -> KnowledgeImageExportItemResult {
    do {
      let sourceURL = try validatedImageExportSource(documentID: document.id)
      let filename = try imageExportFilenameParts(
        sourceName: document.sourceName,
        sourceURL: sourceURL
      )
      let destinationURL: URL
      switch mode {
      case .originalFile:
        destinationURL = try copyOriginalImage(
          at: sourceURL,
          basename: filename.basename,
          pathExtension: filename.pathExtension,
          to: destinationDirectory
        )
      case .privacySanitizedShareCopy:
        destinationURL = try exportPrivacySanitizedImage(
          at: sourceURL,
          basename: filename.basename,
          pathExtension: filename.pathExtension,
          to: destinationDirectory
        )
      }
      return KnowledgeImageExportItemResult(
        documentID: document.id,
        sourceName: document.sourceName,
        outcome: .exported(destinationURL: destinationURL)
      )
    } catch is CancellationError {
      return KnowledgeImageExportItemResult(
        documentID: document.id,
        sourceName: document.sourceName,
        outcome: .failed(reason: CoreL10n.text("导出已取消。"))
      )
    } catch {
      return KnowledgeImageExportItemResult(
        documentID: document.id,
        sourceName: document.sourceName,
        outcome: .failed(reason: error.localizedDescription)
      )
    }
  }

  private func validatedImageExportDestination(_ destinationDirectory: URL) throws -> URL {
    guard destinationDirectory.isFileURL, destinationDirectory.path.hasPrefix("/") else {
      throw KnowledgeLibraryError.exportFailure(CoreL10n.text("目标必须是本机文件夹。"))
    }
    let standardizedDestination = destinationDirectory.standardizedFileURL
    guard fileManager.fileExists(atPath: standardizedDestination.path) else {
      throw KnowledgeLibraryError.exportFailure(CoreL10n.text("目标文件夹不存在。"))
    }
    let values = try standardizedDestination.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw KnowledgeLibraryError.exportFailure(CoreL10n.text("目标必须是普通文件夹。"))
    }
    let resolvedDestination = standardizedDestination.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
    guard !isImageExportPath(resolvedDestination, inside: resolvedRoot) else {
      throw KnowledgeLibraryError.exportFailure(CoreL10n.text("不能导出到资料库目录或其子目录。"))
    }
    return resolvedDestination
  }

  private func validatedImageExportSource(documentID: UUID) throws -> URL {
    guard let revision = try database().currentRevision(documentID: documentID),
      let reference = revision.originalStorageReference?.nilIfEmpty,
      let sourceURL = safeStorageFileURL(for: reference)
    else {
      throw KnowledgeLibraryError.exportFailure(CoreL10n.text("原始图片记录无效。"))
    }
    let sourceValues = try sourceURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
      throw KnowledgeLibraryError.exportFailure(CoreL10n.text("原始图片不可安全读取。"))
    }
    guard let fileSize = sourceValues.fileSize,
      fileSize >= 0,
      fileSize <= knowledgeImageExportMaximumByteCount
    else {
      throw KnowledgeLibraryError.sourceLimitExceeded(CoreL10n.text("图片超过 25 MB，无法导出。"))
    }
    let resolvedSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
    guard isImageExportPath(resolvedSource, inside: resolvedRoot) else {
      throw KnowledgeLibraryError.exportFailure(CoreL10n.text("原始图片路径超出资料库。"))
    }
    return sourceURL
  }

  private func imageExportFilenameParts(
    sourceName: String,
    sourceURL: URL
  ) throws -> (basename: String, pathExtension: String) {
    let trueExtension = sourceURL.pathExtension.lowercased()
    guard !trueExtension.isEmpty,
      trueExtension.count <= 16,
      trueExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
    else {
      throw KnowledgeLibraryError.exportFailure(CoreL10n.text("原始图片缺少安全的文件扩展名。"))
    }
    let sourceBasename = (sourceName as NSString).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let basenameWithoutExtension = (sourceBasename as NSString).deletingPathExtension
    let forbidden = CharacterSet(charactersIn: "/\\:\\?%*|\"<>")
      .union(.controlCharacters)
    let sanitized =
      basenameWithoutExtension
      .components(separatedBy: forbidden)
      .joined(separator: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return (
      basename: String((sanitized.nilIfEmpty ?? CoreL10n.text("未命名图片")).prefix(100)),
      pathExtension: trueExtension
    )
  }

  private func copyOriginalImage(
    at sourceURL: URL,
    basename: String,
    pathExtension: String,
    to destinationDirectory: URL
  ) throws -> URL {
    let stagingURL = imageExportStagingURL(in: destinationDirectory, pathExtension: pathExtension)
    defer { try? fileManager.removeItem(at: stagingURL) }
    try fileManager.copyItem(at: sourceURL, to: stagingURL)
    let stagingValues = try stagingURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard stagingValues.isRegularFile == true,
      let stagingSize = stagingValues.fileSize,
      stagingSize <= knowledgeImageExportMaximumByteCount
    else {
      throw KnowledgeLibraryError.sourceLimitExceeded(CoreL10n.text("图片超过 25 MB，无法导出。"))
    }
    return try publishStagedImage(
      at: stagingURL,
      basename: basename,
      pathExtension: pathExtension,
      to: destinationDirectory
    )
  }

  private func exportPrivacySanitizedImage(
    at sourceURL: URL,
    basename: String,
    pathExtension: String,
    to destinationDirectory: URL
  ) throws -> URL {
    let sanitizer = ImagePrivacySanitizingService()
    let inspection = try sanitizer.inspect(at: sourceURL)
    guard inspection.frameCount == 1 else {
      throw KnowledgeLibraryError.exportFailure(
        CoreL10n.text("多帧图片不能生成移除敏感元数据的分享副本。")
      )
    }
    var collisionIndex = 1
    while collisionIndex <= 10_000 {
      let destinationURL = imageExportDestinationURL(
        basename: basename,
        pathExtension: pathExtension,
        collisionIndex: collisionIndex,
        destinationDirectory: destinationDirectory
      )
      guard !fileManager.fileExists(atPath: destinationURL.path) else {
        collisionIndex += 1
        continue
      }
      do {
        _ = try sanitizer.sanitize(at: sourceURL, to: destinationURL)
        return destinationURL
      } catch ImagePrivacySanitizingError.destinationExists {
        collisionIndex += 1
      }
    }
    throw KnowledgeLibraryError.exportFailure(CoreL10n.text("无法为图片创建不冲突的导出文件名。"))
  }

  private func publishStagedImage(
    at stagingURL: URL,
    basename: String,
    pathExtension: String,
    to destinationDirectory: URL
  ) throws -> URL {
    var collisionIndex = 1
    while collisionIndex <= 10_000 {
      let destinationURL = imageExportDestinationURL(
        basename: basename,
        pathExtension: pathExtension,
        collisionIndex: collisionIndex,
        destinationDirectory: destinationDirectory
      )
      guard !fileManager.fileExists(atPath: destinationURL.path) else {
        collisionIndex += 1
        continue
      }
      do {
        // FileManager refuses an existing destination, so this publishes the
        // already-complete staging file without replacing another export.
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
        return destinationURL
      } catch {
        if fileManager.fileExists(atPath: destinationURL.path) {
          collisionIndex += 1
          continue
        }
        throw error
      }
    }
    throw KnowledgeLibraryError.exportFailure(CoreL10n.text("无法为图片创建不冲突的导出文件名。"))
  }

  private func imageExportDestinationURL(
    basename: String,
    pathExtension: String,
    collisionIndex: Int,
    destinationDirectory: URL
  ) -> URL {
    let suffix = collisionIndex == 1 ? "" : " (\(collisionIndex))"
    return destinationDirectory.appendingPathComponent("\(basename)\(suffix).\(pathExtension)")
  }

  private func imageExportStagingURL(in directory: URL, pathExtension: String) -> URL {
    directory.appendingPathComponent(
      ".image-export-\(UUID().uuidString.lowercased()).stage.\(pathExtension)"
    )
  }

  private func isImageExportPath(_ candidate: URL, inside root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
  }
}
