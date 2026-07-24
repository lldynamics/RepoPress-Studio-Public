import Foundation

extension KnowledgeLibraryService {
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

  func makeImportPreviewSynchronously(
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

  func makeImportPreviewSynchronously(
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

  func makeFolderPreview(
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

  func fileCandidate(
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

  func candidate(
    data: Data,
    sourceName: String,
    sourceURL: URL?,
    fileExtension: String,
    preferredKind: KnowledgeDocumentKind?,
    sourceModifiedAt: Date?,
    options: KnowledgeImportOptions = KnowledgeImportOptions()
  ) throws -> KnowledgeImportCandidate {
    let lowerExtension = fileExtension.lowercased()
    let extraction = try contentExtractionService.extract(
      data: data,
      sourceName: sourceName,
      fileExtension: lowerExtension,
      preferredKind: preferredKind,
      options: options
    )

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
      title: extraction.title.nilIfEmpty ?? contentExtractionService.humanizedFilename(sourceName),
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

  func normalizedText(from sections: [KnowledgeExtractedSection]) -> String {
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

  func makeBrowserImportPreviewSynchronously(
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
    switch capture.captureMode {
    case .cleanedArticle:
      warnings.append("本次使用净化正文模式，只保存适合阅读与检索的正文。")
    case .fullPage:
      warnings.append("本次使用完整网页模式，同时保存可检索正文和页面归档。")
    case .selection:
      warnings.append("本次仅保存用户在网页中选中的文字。")
    case .linkOnly:
      warnings.append("本次仅保存页面标题和原始链接。")
    case nil:
      break
    }
    if archiveFormat == "html", let embeddedCount = capture.archiveEmbeddedResourceCount {
      warnings.append("离线 HTML 已内联 \(embeddedCount) 个图片、样式或字体资源。")
    }
    if let missingCount = capture.archiveMissingResourceCount, missingCount > 0 {
      warnings.append("有 \(missingCount) 个外部资源因跨域、网络或大小限制未能内联；离线外观可能不完整。")
    }
    if capture.archiveWasTruncated == true {
      warnings.append("网页归档已达到 24 MB 上限，已保留可检索正文和可用的精简 HTML。")
    }
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
      allowsAIUse: capture.allowsAIUse,
      originalFilenameExtension: originalExtension,
      originalData: originalData,
      capturedText: capture.contentText,
      originalContentHash: originalHash,
      normalizedText: normalizedText,
      normalizedContentHash: normalizedHash,
      sections: sections,
      warnings: warnings
    )
    return KnowledgeImportPreview(sourceName: sourceURL.absoluteString, candidates: [candidate])
  }

}
