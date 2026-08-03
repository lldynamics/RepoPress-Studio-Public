import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct AssetResourceManagerService: Sendable {
  public static let maximumAssetCount = 10_000
  public static let maximumMarkdownFileCount = 10_000
  public static let maximumMarkdownByteCount = 4 * 1024 * 1024
  public static let compressionMinimumByteCount: Int64 = 256 * 1024
  public static let compressionDimensionThreshold = 1_600
  public static let maximumSafeInputPixelCount = 64_000_000

  private let fileSystem: SendableFileManager
  private var fileManager: FileManager { fileSystem.value }

  public init(fileManager: FileManager = .default) {
    self.fileSystem = SendableFileManager(fileManager)
  }

  public func scanAsync(profile: SiteProfile) async throws -> AssetResourceScanReport {
    let task = Task.detached(priority: .utility) {
      try self.scan(profile: profile)
    }
    let result = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    return result
  }

  public func scan(profile: SiteProfile) throws -> AssetResourceScanReport {
    guard let report = try profile.withLocalRepositoryRootAccess({ rootURL in
      try scan(
        repositoryRootURL: rootURL,
        assetRoot: profile.assetRoot,
        profileID: profile.id
      )
    }) else {
      throw AssetResourceManagerError.repositoryUnavailable
    }
    return report
  }

  public func scan(
    repositoryRootURL: URL,
    assetRoot: String,
    profileID: UUID = UUID()
  ) throws -> AssetResourceScanReport {
    try Task.checkCancellation()
    let canonicalRoot = canonicalFileURL(repositoryRootURL)
    guard directoryExists(canonicalRoot) else {
      throw AssetResourceManagerError.repositoryUnavailable
    }

    let normalizedAssetRoot = try normalizedRelativePath(assetRoot)
    let requestedAssetRootURL = URL(
      fileURLWithPath: canonicalRoot.path + "/" + normalizedAssetRoot,
      isDirectory: true
    )
    let canonicalAssetRoot = canonicalFileURL(requestedAssetRootURL)
    guard requestedAssetRootURL.path == canonicalAssetRoot.path,
          isDescendantOrSame(canonicalAssetRoot, root: canonicalRoot) else {
      throw AssetResourceManagerError.invalidAssetRoot
    }
    guard directoryExists(canonicalAssetRoot) else {
      throw AssetResourceManagerError.assetDirectoryUnavailable(normalizedAssetRoot)
    }

    let markdown = try readMarkdownDocuments(
      in: canonicalRoot,
      root: canonicalRoot
    )
    let references = resolveReferences(
      in: markdown,
      root: canonicalRoot,
      assetRoot: canonicalAssetRoot,
      assetRootPath: normalizedAssetRoot
    )
    let inventory = try readAssets(
      in: canonicalAssetRoot,
      root: canonicalRoot,
      referencesByPath: references.referencesByPath,
      wasTruncatedByMarkdown: markdown.wasTruncated
    )

    return AssetResourceScanReport(
      profileID: profileID,
      repositoryRootPath: canonicalRoot.path,
      assetRootPath: normalizedAssetRoot,
      assets: inventory.assets,
      brokenReferences: references.brokenReferences,
      scannedMarkdownFileCount: markdown.scannedFileCount,
      skippedMarkdownFileCount: markdown.skippedFileCount,
      wasTruncated: markdown.wasTruncated || inventory.wasTruncated
    )
  }

  public func moveOrphanedAssetsToTrash(
    profile: SiteProfile,
    items: [AssetResourceItem]
  ) throws -> AssetResourceCleanupResult {
    guard let result = try profile.withLocalRepositoryRootAccess({ rootURL in
      try moveOrphanedAssetsToTrash(
        repositoryRootURL: rootURL,
        assetRoot: profile.assetRoot,
        items: items
      )
    }) else {
      throw AssetResourceManagerError.repositoryUnavailable
    }
    return result
  }

  public func optimizeAssets(
    profile: SiteProfile,
    items: [AssetResourceItem]
  ) throws -> AssetResourceOptimizationResult {
    guard let result = try profile.withLocalRepositoryRootAccess({ rootURL in
      try optimizeAssets(
        repositoryRootURL: rootURL,
        assetRoot: profile.assetRoot,
        items: items
      )
    }) else {
      throw AssetResourceManagerError.repositoryUnavailable
    }
    return result
  }

  private func moveOrphanedAssetsToTrash(
    repositoryRootURL: URL,
    assetRoot: String,
    items: [AssetResourceItem]
  ) throws -> AssetResourceCleanupResult {
    let validated = try makePathValidator(
      repositoryRootURL: repositoryRootURL,
      assetRoot: assetRoot
    )
    var moved: [String] = []
    var needsReview: [String] = []
    var failed: [String] = []

    for item in items {
      try Task.checkCancellation()
      guard item.isOrphaned else {
        failed.append(item.repositoryPath)
        continue
      }
      do {
        let url = try validated(item)
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        if resultingURL == nil {
          needsReview.append(item.repositoryPath)
        } else {
          moved.append(item.repositoryPath)
        }
      } catch {
        failed.append(item.repositoryPath)
      }
    }

    return AssetResourceCleanupResult(
      movedToTrashPaths: moved,
      needsReviewPaths: needsReview,
      failedPaths: failed
    )
  }

  private func optimizeAssets(
    repositoryRootURL: URL,
    assetRoot: String,
    items: [AssetResourceItem]
  ) throws -> AssetResourceOptimizationResult {
    let validated = try makePathValidator(
      repositoryRootURL: repositoryRootURL,
      assetRoot: assetRoot
    )
    var optimized: [String] = []
    var skipped: [String] = []
    var failed: [String] = []
    var savedBytes: Int64 = 0

    for item in items {
      try Task.checkCancellation()
      guard item.canCompress else {
        skipped.append(item.repositoryPath)
        continue
      }
      do {
        let sourceURL = try validated(item)
        let originalSize = try currentFileSize(at: sourceURL, expected: item.byteSize)
        let temporaryURL = sourceURL
          .deletingLastPathComponent()
          .appendingPathComponent(".asset-manager-\(UUID().uuidString).\(sourceURL.pathExtension)")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try writeOptimizedImage(from: sourceURL, to: temporaryURL)
        try Task.checkCancellation()
        let optimizedSize = try currentFileSize(at: temporaryURL, expected: nil)
        guard optimizedSize < originalSize else {
          skipped.append(item.repositoryPath)
          continue
        }

        _ = try fileManager.replaceItemAt(
          sourceURL,
          withItemAt: temporaryURL,
          backupItemName: nil,
          options: []
        )
        optimized.append(item.repositoryPath)
        savedBytes += originalSize - optimizedSize
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failed.append(item.repositoryPath)
      }
    }

    return AssetResourceOptimizationResult(
      optimizedPaths: optimized,
      savedBytes: savedBytes,
      skippedPaths: skipped,
      failedPaths: failed
    )
  }

  private func writeOptimizedImage(from sourceURL: URL, to destinationURL: URL) throws {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let sourceType = CGImageSourceGetType(source) else {
      throw AssetResourceManagerError.unsafeAssetPath(sourceURL.lastPathComponent)
    }

    guard let dimensions = imageDimensions(at: sourceURL),
          Int64(dimensions.width) * Int64(dimensions.height) <= Self.maximumSafeInputPixelCount else {
      throw AssetResourceManagerError.unsafeAssetPath(sourceURL.lastPathComponent)
    }

    let extensionName = sourceURL.pathExtension.lowercased()
    let destinationType: CFString
    if extensionName == "jpg" || extensionName == "jpeg" {
      destinationType = UTType.jpeg.identifier as CFString
    } else {
      destinationType = sourceType
    }
    guard let destination = CGImageDestinationCreateWithURL(
      destinationURL as CFURL,
      destinationType,
      1,
      nil
    ) else {
      throw AssetResourceManagerError.unsafeAssetPath(sourceURL.lastPathComponent)
    }

    if extensionName == "jpg" || extensionName == "jpeg" || extensionName == "heic" {
      let options = [
        kCGImageDestinationLossyCompressionQuality: 0.80,
      ] as CFDictionary
      CGImageDestinationAddImageFromSource(destination, source, 0, options)
    } else {
      CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    }

    guard CGImageDestinationFinalize(destination) else {
      throw AssetResourceManagerError.unsafeAssetPath(sourceURL.lastPathComponent)
    }
  }

  private func makePathValidator(
    repositoryRootURL: URL,
    assetRoot: String
  ) throws -> (AssetResourceItem) throws -> URL {
    let canonicalRoot = canonicalFileURL(repositoryRootURL)
    let normalizedAssetRoot = try normalizedRelativePath(assetRoot)
    let requestedAssetRoot = URL(
      fileURLWithPath: canonicalRoot.path + "/" + normalizedAssetRoot,
      isDirectory: true
    )
    let canonicalAssetRoot = canonicalFileURL(requestedAssetRoot)
    guard requestedAssetRoot.path == canonicalAssetRoot.path,
          isDescendantOrSame(canonicalAssetRoot, root: canonicalRoot),
          directoryExists(canonicalAssetRoot) else {
      throw AssetResourceManagerError.invalidAssetRoot
    }

    return { item in
      let normalizedPath = try self.normalizedRelativePath(item.repositoryPath)
      guard normalizedPath == normalizedAssetRoot
        || normalizedPath.hasPrefix(normalizedAssetRoot + "/") else {
        throw AssetResourceManagerError.unsafeAssetPath(normalizedPath)
      }
      let requestedURL = URL(fileURLWithPath: canonicalRoot.path + "/" + normalizedPath)
      let canonicalURL = self.canonicalFileURL(requestedURL)
      guard requestedURL.path == canonicalURL.path,
            self.isDescendantOrSame(canonicalURL, root: canonicalAssetRoot),
            self.isDescendantOrSame(canonicalURL, root: canonicalRoot),
            self.fileManager.fileExists(atPath: canonicalURL.path) else {
        throw AssetResourceManagerError.unsafeAssetPath(normalizedPath)
      }
      let values = try canonicalURL.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
      )
      guard values.isRegularFile == true else {
        throw AssetResourceManagerError.unsafeAssetPath(normalizedPath)
      }
      let currentSize = Int64(values.fileSize ?? 0)
      guard currentSize == item.byteSize else {
        throw AssetResourceManagerError.unsafeAssetPath(normalizedPath)
      }
      if let expectedModifiedAt = item.modifiedAt,
         let currentModifiedAt = values.contentModificationDate,
         abs(currentModifiedAt.timeIntervalSince(expectedModifiedAt)) > 0.001 {
        throw AssetResourceManagerError.unsafeAssetPath(normalizedPath)
      }
      return canonicalURL
    }
  }

  private func currentFileSize(at url: URL, expected: Int64?) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw AssetResourceManagerError.unsafeAssetPath(url.lastPathComponent)
    }
    let size = Int64(values.fileSize ?? 0)
    if let expected, size != expected {
      throw AssetResourceManagerError.unsafeAssetPath(url.lastPathComponent)
    }
    return size
  }

  private struct MarkdownReadResult {
    let documents: [(path: String, url: URL, text: String)]
    let scannedFileCount: Int
    let skippedFileCount: Int
    let wasTruncated: Bool
  }

  private func readMarkdownDocuments(in root: URL, root canonicalRoot: URL) throws -> MarkdownReadResult {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return MarkdownReadResult(documents: [], scannedFileCount: 0, skippedFileCount: 0, wasTruncated: false)
    }

    let skippedDirectoryNames: Set<String> = [
      ".git", ".cache", ".next", ".nuxt", ".vercel", ".vite", "build", "dist", "node_modules", "public", "target",
    ]
    var documents: [(path: String, url: URL, text: String)] = []
    var scanned = 0
    var skipped = 0
    var wasTruncated = false

    for case let fileURL as URL in enumerator {
      try Task.checkCancellation()
      let values = try? fileURL.resourceValues(forKeys: keys)
      if values?.isSymbolicLink == true {
        if values?.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      if values?.isDirectory == true {
        if skippedDirectoryNames.contains(fileURL.lastPathComponent.lowercased()) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values?.isRegularFile == true,
            AssetResourceFileSupport.markdownExtensions.contains(fileURL.pathExtension.lowercased()) else {
        continue
      }
      guard let relativePath = relativePath(of: fileURL, root: canonicalRoot) else { continue }
      guard documents.count < Self.maximumMarkdownFileCount else {
        wasTruncated = true
        break
      }
      let byteSize = Int64(values?.fileSize ?? 0)
      guard byteSize <= Self.maximumMarkdownByteCount else {
        skipped += 1
        continue
      }
      do {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        documents.append((relativePath, fileURL, text))
        scanned += 1
      } catch {
        skipped += 1
      }
    }

    return MarkdownReadResult(
      documents: documents,
      scannedFileCount: scanned,
      skippedFileCount: skipped,
      wasTruncated: wasTruncated
    )
  }

  private struct ReferenceResolutionResult {
    let referencesByPath: [String: [AssetResourceReferenceLocation]]
    let brokenReferences: [AssetResourceBrokenReference]
  }

  private func resolveReferences(
    in markdown: MarkdownReadResult,
    root: URL,
    assetRoot: URL,
    assetRootPath: String
  ) -> ReferenceResolutionResult {
    var referencesByPath: [String: [AssetResourceReferenceLocation]] = [:]
    var brokenReferences: [AssetResourceBrokenReference] = []

    for document in markdown.documents {
      for candidate in extractReferences(text: document.text, documentPath: document.path) {
        guard let resolution = resolve(
          rawPath: candidate.rawPath,
          isImageSyntax: candidate.isImageSyntax,
          sourceDocumentURL: document.url,
          root: root,
          assetRoot: assetRoot,
          assetRootPath: assetRootPath
        ) else {
          continue
        }
        guard resolution.shouldInspect else { continue }
        let location = AssetResourceReferenceLocation(
          sourceMarkdownPath: document.path,
          lineNumber: candidate.lineNumber,
          rawPath: candidate.rawPath,
          isImageSyntax: candidate.isImageSyntax
        )

        if let existingAssetPath = resolution.existingAssetPath {
          referencesByPath[existingAssetPath, default: []].append(location)
        } else if let issue = resolution.issue {
          brokenReferences.append(
            AssetResourceBrokenReference(
              sourceMarkdownPath: document.path,
              lineNumber: candidate.lineNumber,
              rawPath: candidate.rawPath,
              kind: issue.kind,
              message: issue.message
            )
          )
        }
      }
    }

    return ReferenceResolutionResult(
      referencesByPath: referencesByPath,
      brokenReferences: brokenReferences.sorted {
        if $0.sourceMarkdownPath == $1.sourceMarkdownPath {
          return $0.lineNumber < $1.lineNumber
        }
        return $0.sourceMarkdownPath.localizedStandardCompare($1.sourceMarkdownPath) == .orderedAscending
      }
    )
  }

  private struct ExtractedReference {
    let rawPath: String
    let lineNumber: Int
    let isImageSyntax: Bool
  }

  private func extractReferences(text: String, documentPath: String) -> [ExtractedReference] {
    let source = text as NSString
    let protectedRanges = MarkdownCodeRangeScanner.scan(text).allRanges
    var references: [ExtractedReference] = []
    let inlinePattern = #"(?m)(!?)\[[^\]]*\]\(\s*(?:<([^>\r\n]+)>|([^\s)\r\n]+))"#
    let definitionPattern = #"(?m)^\s*(!?)\[[^\]\r\n]+\]:\s*(?:<([^>\r\n]+)>|([^\s\r\n]+))"#
    let attributePattern = #"(?i)\b(src|href|poster)\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))"#

    for (pattern, isAttribute) in [
      (inlinePattern, false),
      (definitionPattern, false),
      (attributePattern, true),
    ] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
      for match in matches {
        guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else {
          continue
        }
        let pathCaptureIndexes: [Int] = isAttribute ? [2, 3, 4] : [2, 3]
        let rawPath = pathCaptureIndexes.lazy
          .filter { $0 < match.numberOfRanges && match.range(at: $0).location != NSNotFound }
          .map { source.substring(with: match.range(at: $0)) }
          .first
        guard let rawPath, !rawPath.trimmedForPublishing.isEmpty else { continue }
        let isImageSyntax: Bool
        if isAttribute {
          let attribute = source.substring(with: match.range(at: 1)).lowercased()
          isImageSyntax = attribute != "href"
        } else {
          isImageSyntax = match.range(at: 1).location != NSNotFound
            && source.substring(with: match.range(at: 1)) == "!"
        }
        let lineNumber = lineNumber(in: source, atUTF16Offset: match.range.location)
        references.append(
          ExtractedReference(
            rawPath: rawPath,
            lineNumber: lineNumber,
            isImageSyntax: isImageSyntax
          )
        )
      }
    }

    return references
  }

  private struct ReferenceResolution {
    let shouldInspect: Bool
    let existingAssetPath: String?
    let issue: (kind: AssetResourceReferenceIssueKind, message: String)?
  }

  private func resolve(
    rawPath: String,
    isImageSyntax: Bool,
    sourceDocumentURL: URL,
    root: URL,
    assetRoot: URL,
    assetRootPath: String
  ) -> ReferenceResolution? {
    let decoded = (rawPath.removingPercentEncoding ?? rawPath)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\", with: "/")
    guard !decoded.isEmpty, !decoded.hasPrefix("#") else { return nil }
    guard !isRemoteOrNonFileURL(decoded) else { return nil }

    let pathWithoutFragment = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? decoded
    let path = pathWithoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? pathWithoutFragment
    guard !path.isEmpty else { return nil }

    let explicitAssetPath = path == assetRootPath || path.hasPrefix(assetRootPath + "/")
    let relativeCandidate: String
    if path.hasPrefix("/") {
      relativeCandidate = joinRelative(assetRootPath, String(path.drop(while: { $0 == "/" })))
    } else if explicitAssetPath {
      relativeCandidate = path
    } else {
      let documentDirectory = sourceDocumentURL.deletingLastPathComponent()
      let documentRelative = canonicalFileURL(documentDirectory.appendingPathComponent(path))
      guard isDescendantOrSame(documentRelative, root: root) else {
        return likelyAssetReference(path: path, isImageSyntax: isImageSyntax)
          ? ReferenceResolution(
            shouldInspect: true,
            existingAssetPath: nil,
            issue: (.outsideRepository, CoreL10n.text("本地资源路径越出了仓库目录。"))
          )
          : nil
      }
      relativeCandidate = relativePath(of: documentRelative, root: root) ?? path
    }

    var requestedURL = URL(fileURLWithPath: root.path + "/" + relativeCandidate)
    if !explicitAssetPath,
       !path.hasPrefix("/"),
       !path.split(separator: "/").contains(".."),
       !fileManager.fileExists(atPath: requestedURL.path) {
      let assetFallbackPath = joinRelative(assetRootPath, path)
      let fallbackURL = URL(fileURLWithPath: root.path + "/" + assetFallbackPath)
      if fileManager.fileExists(atPath: fallbackURL.path) {
        requestedURL = fallbackURL
      }
    }
    let canonicalURL = canonicalFileURL(requestedURL)
    let isInsideRoot = isDescendantOrSame(canonicalURL, root: root)
    let isInsideAssetRoot = isDescendantOrSame(canonicalURL, root: assetRoot)
    let candidateLooksLikeAsset = likelyAssetReference(
      path: path,
      isImageSyntax: isImageSyntax
    ) || isImageSyntaxPath(path)

    guard candidateLooksLikeAsset || isInsideAssetRoot else { return nil }
    guard isInsideRoot else {
      return ReferenceResolution(
        shouldInspect: true,
        existingAssetPath: nil,
        issue: (.outsideRepository, CoreL10n.text("本地资源路径越出了仓库目录。"))
      )
    }
    guard isInsideAssetRoot else {
      if fileManager.fileExists(atPath: canonicalURL.path) {
        return ReferenceResolution(
          shouldInspect: true,
          existingAssetPath: nil,
          issue: (.outsideAssetRoot, CoreL10n.text("文件存在，但不在当前配置的资源目录内。"))
        )
      }
      return candidateLooksLikeAsset
        ? ReferenceResolution(
          shouldInspect: true,
          existingAssetPath: nil,
          issue: (.outsideAssetRoot, CoreL10n.text("引用路径不在当前配置的资源目录内。"))
        )
        : nil
    }

    guard fileManager.fileExists(atPath: canonicalURL.path) else {
      return ReferenceResolution(
        shouldInspect: true,
        existingAssetPath: nil,
        issue: (.missing, CoreL10n.text("本地资源文件不存在。"))
      )
    }
    let values = try? canonicalURL.resourceValues(forKeys: [.isRegularFileKey])
    guard values?.isRegularFile == true else {
      return ReferenceResolution(
        shouldInspect: true,
        existingAssetPath: nil,
        issue: (.missing, CoreL10n.text("本地资源路径不是可读取的文件。"))
      )
    }
    guard let repositoryPath = relativePath(of: canonicalURL, root: root),
          AssetResourceFileSupport.isSupportedPath(repositoryPath) else {
      return ReferenceResolution(
        shouldInspect: true,
        existingAssetPath: nil,
        issue: (.unsupported, CoreL10n.text("该本地文件格式不在资源管理器支持范围内。"))
      )
    }
    return ReferenceResolution(
      shouldInspect: true,
      existingAssetPath: repositoryPath.normalizedRelativePath(),
      issue: nil
    )
  }

  private func readAssets(
    in assetRoot: URL,
    root: URL,
    referencesByPath: [String: [AssetResourceReferenceLocation]],
    wasTruncatedByMarkdown: Bool
  ) throws -> (assets: [AssetResourceItem], wasTruncated: Bool) {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      .fileSizeKey, .contentModificationDateKey,
    ]
    guard let enumerator = fileManager.enumerator(
      at: assetRoot,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      throw AssetResourceManagerError.assetDirectoryUnavailable(assetRoot.path)
    }

    var assets: [AssetResourceItem] = []
    var wasTruncated = wasTruncatedByMarkdown
    for case let fileURL as URL in enumerator {
      try Task.checkCancellation()
      let values = try? fileURL.resourceValues(forKeys: keys)
      if values?.isSymbolicLink == true {
        if values?.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard values?.isRegularFile == true,
            let kind = AssetResourceFileSupport.kind(for: fileURL.path),
            let repositoryPath = relativePath(of: fileURL, root: root) else {
        continue
      }
      let canonicalURL = canonicalFileURL(fileURL)
      guard isDescendantOrSame(canonicalURL, root: assetRoot),
            isDescendantOrSame(canonicalURL, root: root) else { continue }
      if assets.count >= Self.maximumAssetCount {
        wasTruncated = true
        break
      }

      let normalizedPath = repositoryPath.normalizedRelativePath()
      let byteSize = Int64(values?.fileSize ?? 0)
      let dimensions = kind == .image ? imageDimensions(at: canonicalURL) : nil
      let extensionName = canonicalURL.pathExtension.lowercased()
      let isCompressibleExtension = AssetResourceFileSupport.compressibleImageExtensions.contains(extensionName)
      let isLarge = byteSize >= Self.compressionMinimumByteCount
        || dimensions.map { max($0.width, $0.height) >= Self.compressionDimensionThreshold } == true
      let canCompress = kind == .image && isCompressibleExtension && isLarge
      let reason: String?
      if byteSize >= Self.compressionMinimumByteCount {
        reason = CoreL10n.text("文件体积较大")
      } else if dimensions.map({ max($0.width, $0.height) >= Self.compressionDimensionThreshold }) == true {
        reason = CoreL10n.text("图片尺寸较大")
      } else {
        reason = nil
      }

      assets.append(
        AssetResourceItem(
          repositoryPath: normalizedPath,
          absoluteFilePath: canonicalURL.path,
          filename: canonicalURL.lastPathComponent,
          fileExtension: canonicalURL.pathExtension.uppercased(),
          kind: kind,
          byteSize: byteSize,
          modifiedAt: values?.contentModificationDate,
          dimensions: dimensions,
          references: referencesByPath[normalizedPath] ?? [],
          canCompress: canCompress,
          compressionReason: reason
        )
      )
    }

    assets.sort {
      $0.repositoryPath.localizedStandardCompare($1.repositoryPath) == .orderedAscending
    }
    return (assets, wasTruncated)
  }

  private func imageDimensions(at url: URL) -> ImageDimensions? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          width.intValue > 0,
          height.intValue > 0 else {
      return nil
    }
    return ImageDimensions(width: width.intValue, height: height.intValue)
  }

  private func lineNumber(in source: NSString, atUTF16Offset offset: Int) -> Int {
    guard offset > 0 else { return 1 }
    let prefix = source.substring(with: NSRange(location: 0, length: min(offset, source.length)))
    return prefix.reduce(into: 1) { result, character in
      if character == "\n" { result += 1 }
    }
  }

  private func likelyAssetReference(path: String, isImageSyntax: Bool) -> Bool {
    if isImageSyntax || isImageSyntaxPath(path) { return true }
    if AssetResourceFileSupport.isSupportedPath(path) { return true }
    let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
    return ["/images/", "/image/", "/media/", "/assets/", "/attachments/", "/files/"].contains { normalized.contains($0) }
      || ["images/", "image/", "media/", "assets/", "attachments/", "files/"].contains { normalized.hasPrefix($0) }
  }

  private func isImageSyntaxPath(_ path: String) -> Bool {
    ImageFileSupport.isSupportedImagePath(path)
  }

  private func isRemoteOrNonFileURL(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    if lowercased.hasPrefix("//")
      || lowercased.hasPrefix("http://")
      || lowercased.hasPrefix("https://")
      || lowercased.hasPrefix("data:")
      || lowercased.hasPrefix("mailto:")
      || lowercased.hasPrefix("tel:")
      || lowercased.hasPrefix("javascript:") {
      return true
    }
    return URL(string: value)?.scheme != nil
  }

  private func joinRelative(_ first: String, _ second: String) -> String {
    [first, second]
      .filter { !$0.isEmpty }
      .joined(separator: "/")
  }

  private func normalizedRelativePath(_ path: String) throws -> String {
    let trimmed = path.trimmedForPublishing.replacingOccurrences(of: "\\", with: "/")
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("/"),
          !components.contains(where: { $0 == ".." }) else {
      throw AssetResourceManagerError.invalidAssetRoot
    }
    let normalized = trimmed.normalizedRelativePath()
    guard !normalized.isEmpty else {
      throw AssetResourceManagerError.invalidAssetRoot
    }
    return normalized
  }

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  private func canonicalFileURL(_ url: URL) -> URL {
    let standardizedPath = lexicallyStandardizedPath(url.path)
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolvedPath: String? = standardizedPath.withCString { path in
      buffer.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress,
              let resolved = realpath(path, baseAddress) else {
          return nil
        }
        return String(cString: resolved)
      }
    }
    return URL(
      fileURLWithPath: resolvedPath ?? standardizedPath,
      isDirectory: url.hasDirectoryPath
    )
  }

  private func lexicallyStandardizedPath(_ path: String) -> String {
    let isAbsolute = path.hasPrefix("/")
    var components: [String] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        if let last = components.last, last != ".." {
          components.removeLast()
        } else if !isAbsolute {
          components.append("..")
        }
      default:
        components.append(String(component))
      }
    }
    let joined = components.joined(separator: "/")
    if isAbsolute {
      return joined.isEmpty ? "/" : "/" + joined
    }
    return joined
  }

  private func isDescendantOrSame(_ candidate: URL, root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
  }

  private func relativePath(of candidate: URL, root: URL) -> String? {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard candidate.path.hasPrefix(rootPath) else { return nil }
    return String(candidate.path.dropFirst(rootPath.count))
  }
}
