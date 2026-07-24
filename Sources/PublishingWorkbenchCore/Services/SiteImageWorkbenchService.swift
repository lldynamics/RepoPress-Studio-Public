import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif
public struct SiteImageWorkbenchService: Sendable {
  public typealias AsyncReportOperation = @Sendable (ArticleDraft, SiteProfile) async throws -> ImageWorkbenchReport
  public typealias AsyncSiteSummaryOperation = @Sendable ([ArticleDraft], SiteProfile) async throws -> ImageWorkbenchSiteSummary

  private let fileSystem: SendableFileManager
  private let cwebPExecutableOverride: URL?
  private let cwebPTimeout: TimeInterval
  private let prefersCWebP: Bool
  private let asyncReportOperation: AsyncReportOperation?
  private let asyncSiteSummaryOperation: AsyncSiteSummaryOperation?

  private var fileManager: FileManager { fileSystem.value }

  public static var supportsWebPEncoding: Bool {
    supportsImageIOWebPEncoding || cwebPExecutableURL != nil
  }

  private static var supportsImageIOWebPEncoding: Bool {
    let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    guard identifiers.contains(UTType.webP.identifier) else {
      return false
    }
    guard let data = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(
            data,
            UTType.webP.identifier as CFString,
            1,
            nil
          ),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let image = context.makeImage() else {
      return false
    }

    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
  }

  private static var cwebPExecutableURL: URL? {
    [
      "/opt/homebrew/bin/cwebp",
      "/usr/local/bin/cwebp",
      "/usr/bin/cwebp",
    ]
      .map { URL(fileURLWithPath: $0) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  public init(
    fileManager: FileManager = .default,
    cwebPExecutableURL: URL? = nil,
    cwebPTimeout: TimeInterval = 30,
    prefersCWebP: Bool = false,
    asyncReportOperation: AsyncReportOperation? = nil,
    asyncSiteSummaryOperation: AsyncSiteSummaryOperation? = nil
  ) {
    self.fileSystem = SendableFileManager(fileManager)
    self.cwebPExecutableOverride = cwebPExecutableURL
    self.cwebPTimeout = max(0.1, cwebPTimeout)
    self.prefersCWebP = prefersCWebP
    self.asyncReportOperation = asyncReportOperation
    self.asyncSiteSummaryOperation = asyncSiteSummaryOperation
  }

  /// Performs file-backed image inspection away from the caller's actor.
  /// The synchronous API remains available for explicit publishing and AI actions.
  public func reportAsync(draft: ArticleDraft, profile: SiteProfile) async throws -> ImageWorkbenchReport {
    if let asyncReportOperation {
      return try await asyncReportOperation(draft, profile)
    }

    let task = Task.detached(priority: .userInitiated) {
      try makeReport(
        draft: draft,
        profile: profile,
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Builds the site-wide image summary away from the caller's actor.
  public func siteSummaryAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) async throws -> ImageWorkbenchSiteSummary {
    if let asyncSiteSummaryOperation {
      return try await asyncSiteSummaryOperation(drafts, profile)
    }

    let task = Task.detached(priority: .utility) {
      try makeSiteSummary(
        drafts: drafts,
        profile: profile,
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func report(draft: ArticleDraft, profile: SiteProfile) -> ImageWorkbenchReport {
    do {
      return try makeReport(draft: draft, profile: profile, cancellationCheck: {})
    } catch {
      preconditionFailure("A non-cancellable image report unexpectedly failed: \(error)")
    }
  }

  private func makeReport(
    draft: ArticleDraft,
    profile: SiteProfile,
    cancellationCheck: () throws -> Void
  ) throws -> ImageWorkbenchReport {
    try cancellationCheck()
    let imageAttachments = draft.attachments.filter { $0.mediaKind == .image }
    let markdownImagePathCounts = localMarkdownImagePathCounts(in: draft.bodyMarkdown)
    let markdownImagePaths = Set(markdownImagePathCounts.keys)
    let registeredPublishPaths = Set(imageAttachments.map(\.relativePublishPath))
    let publishPathCounts = duplicateCounts(
      imageAttachments.map { normalizedPublishPath($0.relativePublishPath) }
    )
    let sourcePathCounts = duplicateCounts(
      imageAttachments.map { normalizedSourcePath($0.sourceFilePath) }
    )
    var issues: [ImageWorkbenchIssue] = []

    let items = try imageAttachments.map { attachment in
      try cancellationCheck()
      let sourceURL = attachment.sourceFilePath.map { URL(fileURLWithPath: $0) }
      let fileExists = sourceURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
      let actualByteSize = sourceURL.flatMap { fileByteSize(at: $0) } ?? attachment.byteSize
      let dimensions = sourceURL.flatMap { imageDimensions(at: $0) }
      let missingAltText = attachment.altText.trimmedForPublishing.isEmpty
      let missingCaption = attachment.caption.trimmedForPublishing.isEmpty
      let isReferenced = markdownImagePaths.contains(attachment.relativePublishPath)
      let isCover = draft.coverAttachmentID == attachment.id
      let isJPEG = isJPEGFilename(sourceURL?.lastPathComponent ?? attachment.originalFilename)
      let canOptimizeJPEG = fileExists && isJPEG && actualByteSize > 0
      let canConvertToWebP = fileExists && isWebPConvertibleFilename(sourceURL?.lastPathComponent ?? attachment.originalFilename)
      let canOptimizeSVG = fileExists && isSVGFilename(sourceURL?.lastPathComponent ?? attachment.originalFilename) && actualByteSize > 0
      let canResizeImage = fileExists
        && isResizableRasterFilename(sourceURL?.lastPathComponent ?? attachment.originalFilename)
        && (dimensions.map { max($0.width, $0.height) > 1_600 } ?? false)
      let normalizedPublishPath = normalizedPublishPath(attachment.relativePublishPath)
      let normalizedSourcePath = normalizedSourcePath(attachment.sourceFilePath)
      let duplicatePublishCount = normalizedPublishPath.map { publishPathCounts[$0] ?? 0 } ?? 0
      let duplicateSourceCount = normalizedSourcePath.map { sourcePathCounts[$0] ?? 0 } ?? 0
      let duplicateMarkdownCount = markdownImagePathCounts[attachment.relativePublishPath] ?? 0
      let duplicateReferenceCount =
        max(0, duplicatePublishCount - 1)
        + max(0, duplicateSourceCount - 1)
        + max(0, duplicateMarkdownCount - 1)

      if missingAltText {
        issues.append(
          ImageWorkbenchIssue(
            severity: .warning,
            title: "缺少 alt 文本",
            message: "\(attachment.originalFilename) 需要可发布的替代文本。",
            attachmentID: attachment.id
          )
        )
      }

      if missingCaption {
        issues.append(
          ImageWorkbenchIssue(
            severity: .info,
            title: "缺少 caption",
            message: "\(attachment.originalFilename) 还没有图片说明。",
            attachmentID: attachment.id
          )
        )
      }

      if !fileExists {
        issues.append(
          ImageWorkbenchIssue(
            severity: .error,
            title: "源文件不可用",
            message: "\(attachment.originalFilename) 的本地源文件不存在，发布时无法复制。",
            attachmentID: attachment.id
          )
        )
      }

      if attachment.relativePublishPath.trimmedForPublishing.isEmpty {
        issues.append(
          ImageWorkbenchIssue(
            severity: .error,
            title: "发布引用为空",
            message: "\(attachment.originalFilename) 缺少 Markdown 中可用的公开图片路径。",
            attachmentID: attachment.id
          )
        )
      }

      if attachment.repositoryPath.contains("..") {
        issues.append(
          ImageWorkbenchIssue(
            severity: .error,
            title: "仓库路径不安全",
            message: "\(attachment.repositoryPath) 不能包含 ..。",
            attachmentID: attachment.id
          )
        )
      }

      if actualByteSize > 1_500_000 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .warning,
            title: "图片体积偏大",
            message: "\(attachment.originalFilename) 超过 1.5 MB，建议发布前压缩。",
            attachmentID: attachment.id
          )
        )
      }

      if let dimensions, max(dimensions.width, dimensions.height) > 2_400 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .info,
            title: "尺寸偏大",
            message: "\(attachment.originalFilename) 为 \(dimensions.displayName)，确认是否需要这么大的发布尺寸。",
            attachmentID: attachment.id
          )
        )
      }

      if !isReferenced && !isCover {
        issues.append(
          ImageWorkbenchIssue(
            severity: .info,
            title: "正文未引用",
            message: "\(attachment.originalFilename) 不在正文 Markdown 中，也不是封面图。",
            attachmentID: attachment.id
          )
        )
      }

      if duplicatePublishCount > 1 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .warning,
            title: "图片发布路径重复",
            message: "\(attachment.relativePublishPath) 被 \(duplicatePublishCount) 个附件共用，发布时可能覆盖或重复引用同一张图片。",
            attachmentID: attachment.id
          )
        )
      }

      if duplicateSourceCount > 1 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .warning,
            title: "源图重复使用",
            message: "\(attachment.originalFilename) 与其他附件指向同一个本地源文件，确认是否需要合并引用。",
            attachmentID: attachment.id
          )
        )
      }

      if duplicateMarkdownCount > 1 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .info,
            title: "正文重复引用图片",
            message: "\(attachment.relativePublishPath) 在正文中出现 \(duplicateMarkdownCount) 次，确认是否为有意重复。",
            attachmentID: attachment.id
          )
        )
      }

      return ImageWorkbenchItem(
        attachmentID: attachment.id,
        originalFilename: attachment.originalFilename,
        relativePublishPath: attachment.relativePublishPath,
        repositoryPath: attachment.repositoryPath,
        sourceFilePath: attachment.sourceFilePath,
        byteSize: actualByteSize,
        dimensions: dimensions,
        fileExists: fileExists,
        isCover: isCover,
        isReferencedInMarkdown: isReferenced,
        missingAltText: missingAltText,
        missingCaption: missingCaption,
        canOptimizeJPEG: canOptimizeJPEG,
        canConvertToWebP: canConvertToWebP,
        canOptimizeSVG: canOptimizeSVG,
        canResizeImage: canResizeImage,
        duplicateReferenceCount: duplicateReferenceCount
      )
    }

    if profile.includeCoverInFrontMatter, let coverID = draft.coverAttachmentID {
      if !draft.attachments.contains(where: { $0.id == coverID }) {
        issues.append(
          ImageWorkbenchIssue(
            severity: .error,
            title: "封面附件丢失",
            message: "Front Matter 指向的封面图片不在当前附件列表中。",
            attachmentID: coverID
          )
        )
      }
    }

    try cancellationCheck()
    for markdownPath in markdownImagePaths where !registeredPublishPaths.contains(markdownPath) {
      issues.append(
        ImageWorkbenchIssue(
          severity: .warning,
          title: "正文图片未登记",
          message: "\(markdownPath) 在正文中使用，但不在附件列表里。"
        )
      )
    }

    for (markdownPath, count) in markdownImagePathCounts where count > 1 && !registeredPublishPaths.contains(markdownPath) {
      issues.append(
        ImageWorkbenchIssue(
          severity: .info,
          title: "正文重复引用图片",
          message: "\(markdownPath) 在正文中出现 \(count) 次，但还没有登记为图片附件。"
        )
      )
    }

    if items.isEmpty {
      issues.append(
        ImageWorkbenchIssue(
          severity: .info,
          title: "还没有图片",
          message: "当前文章没有图片附件。"
        )
      )
    }

    return ImageWorkbenchReport(
      draftID: draft.id,
      items: items,
      coverStatus: coverPublishStatus(draft: draft, profile: profile, items: items),
      issues: issues.sorted {
        if $0.severity.sortRank == $1.severity.sortRank {
          return $0.title < $1.title
        }
        return $0.severity.sortRank < $1.severity.sortRank
      }
    )
  }

  public func imageTextTargets(
    draft: ArticleDraft,
    profile: SiteProfile,
    report: ImageWorkbenchReport? = nil
  ) -> [AIPublishingImageTextTarget] {
    let currentReport = report ?? self.report(draft: draft, profile: profile)
    let itemsByID = Dictionary(uniqueKeysWithValues: currentReport.items.map { ($0.attachmentID, $0) })
    let markdownPath = profile.markdownPath(for: draft)

    return draft.attachments.compactMap { attachment in
      guard let item = itemsByID[attachment.id],
            item.missingAltText || item.missingCaption,
            !attachment.relativePublishPath.trimmedForPublishing.isEmpty
      else {
        return nil
      }

      let title = draft.title.trimmedForPublishing.nilIfEmpty ?? markdownPath
      return AIPublishingImageTextTarget(
        id: attachment.id.uuidString,
        draftID: draft.id,
        attachmentID: attachment.id,
        draftTitle: title,
        markdownPath: markdownPath,
        articleSummary: draft.summary,
        articleExcerpt: draft.bodyMarkdown.trimmedForPublishing,
        filename: attachment.originalFilename,
        imagePath: attachment.relativePublishPath,
        existingAlt: attachment.altText,
        existingCaption: attachment.caption,
        isCover: item.isCover,
        isReferencedInMarkdown: item.isReferencedInMarkdown
      )
    }
  }

  public func applyImageTextSuggestions(
    _ suggestions: [AIPublishingImageTextSuggestion],
    to draft: ArticleDraft
  ) -> ImageTextSuggestionApplyResult {
    let suggestionsByAttachmentID = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.attachmentID, $0) })
    var updatedDraft = draft
    var appliedAltTextCount = 0
    var appliedCaptionCount = 0
    var updatedMarkdownReferenceCount = 0

    for index in updatedDraft.attachments.indices {
      let attachment = updatedDraft.attachments[index]
      guard attachment.mediaKind == .image else { continue }
      guard let suggestion = suggestionsByAttachmentID[attachment.id] else {
        continue
      }

      let suggestedAlt = suggestion.altText.trimmedForPublishing
      let suggestedCaption = suggestion.caption.trimmedForPublishing

      if attachment.altText.trimmedForPublishing.isEmpty, !suggestedAlt.isEmpty {
        updatedDraft.attachments[index].altText = suggestedAlt
        appliedAltTextCount += 1
      }

      if attachment.caption.trimmedForPublishing.isEmpty, !suggestedCaption.isEmpty {
        updatedDraft.attachments[index].caption = suggestedCaption
        appliedCaptionCount += 1
      }

      let markdownAlt = updatedDraft.attachments[index].altText.trimmedForPublishing.nilIfEmpty ?? suggestedAlt
      if !markdownAlt.isEmpty {
        let replacement = replaceEmptyMarkdownAlt(
          in: updatedDraft.bodyMarkdown,
          imagePath: attachment.relativePublishPath,
          altText: markdownAlt
        )
        updatedDraft.bodyMarkdown = replacement.text
        updatedMarkdownReferenceCount += replacement.replacementCount
      }
    }

    return ImageTextSuggestionApplyResult(
      draft: updatedDraft,
      appliedAltTextCount: appliedAltTextCount,
      appliedCaptionCount: appliedCaptionCount,
      updatedMarkdownReferenceCount: updatedMarkdownReferenceCount
    )
  }

  public func siteSummary(drafts: [ArticleDraft], profile: SiteProfile) -> ImageWorkbenchSiteSummary {
    do {
      return try makeSiteSummary(drafts: drafts, profile: profile, cancellationCheck: {})
    } catch {
      preconditionFailure("A non-cancellable image summary unexpectedly failed: \(error)")
    }
  }

  private func makeSiteSummary(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    cancellationCheck: () throws -> Void
  ) throws -> ImageWorkbenchSiteSummary {
    try cancellationCheck()
    let reports = try drafts.map { draft in
      try cancellationCheck()
      return (
        draft: draft,
        report: try makeReport(
          draft: draft,
          profile: profile,
          cancellationCheck: cancellationCheck
        )
      )
    }
    let draftSummaries = reports.map { draft, report in
      ImageWorkbenchDraftSummary(
        draftID: draft.id,
        draftTitle: draft.title,
        imageCount: report.items.count,
        issueCount: visibleIssueCount(report),
        errorCount: visibleIssueCount(report, severity: .error),
        warningCount: visibleIssueCount(report, severity: .warning),
        missingAltTextCount: report.missingAltTextCount,
        missingCaptionCount: report.missingCaptionCount,
        missingSourceCount: report.missingSourceCount,
        optimizableJPEGCount: report.optimizableJPEGCount,
        webPConvertibleCount: report.webPConvertibleCount,
        optimizableSVGCount: report.optimizableSVGCount,
        resizableImageCount: report.resizableImageCount,
        duplicateImageCount: report.duplicateImageCount,
        items: report.items,
        issues: stableSummaryIssues(report.issues, draftID: report.draftID)
      )
    }
    .sorted {
      if $0.errorCount == $1.errorCount {
        if $0.warningCount == $1.warningCount {
          return $0.draftTitle.localizedCaseInsensitiveCompare($1.draftTitle) == .orderedAscending
        }
        return $0.warningCount > $1.warningCount
      }
      return $0.errorCount > $1.errorCount
    }

    return ImageWorkbenchSiteSummary(
      draftCount: drafts.count,
      imageCount: reports.reduce(0) { $0 + $1.report.items.count },
      totalByteSize: reports.reduce(0) { $0 + $1.report.totalByteSize },
      issueCount: reports.reduce(0) { $0 + visibleIssueCount($1.report) },
      errorCount: reports.reduce(0) { $0 + visibleIssueCount($1.report, severity: .error) },
      warningCount: reports.reduce(0) { $0 + visibleIssueCount($1.report, severity: .warning) },
      missingAltTextCount: reports.reduce(0) { $0 + $1.report.missingAltTextCount },
      missingCaptionCount: reports.reduce(0) { $0 + $1.report.missingCaptionCount },
      missingSourceCount: reports.reduce(0) { $0 + $1.report.missingSourceCount },
      optimizableJPEGCount: reports.reduce(0) { $0 + $1.report.optimizableJPEGCount },
      webPConvertibleCount: reports.reduce(0) { $0 + $1.report.webPConvertibleCount },
      optimizableSVGCount: reports.reduce(0) { $0 + $1.report.optimizableSVGCount },
      resizableImageCount: reports.reduce(0) { $0 + $1.report.resizableImageCount },
      duplicateImageCount: reports.reduce(0) { $0 + $1.report.duplicateImageCount },
      draftSummaries: draftSummaries
    )
  }

  public func fillMissingMetadata(
    draft: ArticleDraft,
    includedAttachmentIDs: Set<UUID>? = nil
  ) -> ImageMetadataFillResult {
    var updatedDraft = draft
    var filledAltTextCount = 0
    var filledCaptionCount = 0
    var updatedMarkdownReferenceCount = 0

    for index in updatedDraft.attachments.indices {
      guard updatedDraft.attachments[index].mediaKind == .image else { continue }
      if let includedAttachmentIDs,
         !includedAttachmentIDs.contains(updatedDraft.attachments[index].id) {
        continue
      }
      let originalAlt = updatedDraft.attachments[index].altText
      let fallback = humanizedFilename(updatedDraft.attachments[index].originalFilename)
      let resolvedAlt = originalAlt.trimmedForPublishing.nilIfEmpty ?? fallback

      if originalAlt.trimmedForPublishing.isEmpty {
        updatedDraft.attachments[index].altText = resolvedAlt
        filledAltTextCount += 1
      }

      if updatedDraft.attachments[index].caption.trimmedForPublishing.isEmpty {
        updatedDraft.attachments[index].caption = resolvedAlt
        filledCaptionCount += 1
      }

      let replacement = replaceEmptyMarkdownAlt(
        in: updatedDraft.bodyMarkdown,
        imagePath: updatedDraft.attachments[index].relativePublishPath,
        altText: resolvedAlt
      )
      updatedDraft.bodyMarkdown = replacement.text
      updatedMarkdownReferenceCount += replacement.replacementCount
    }

    return ImageMetadataFillResult(
      draft: updatedDraft,
      filledAltTextCount: filledAltTextCount,
      filledCaptionCount: filledCaptionCount,
      updatedMarkdownReferenceCount: updatedMarkdownReferenceCount
    )
  }

  public func optimizeJPEGAttachments(
    draft: ArticleDraft,
    destinationDirectory: URL,
    quality: CGFloat = 0.72,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var optimizedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard isJPEGFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
        skippedCount += 1
        continue
      }

      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
      guard originalSize > 0 else {
        skippedCount += 1
        continue
      }

      let optimizedURL = destinationDirectory
        .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename)).jpg")

      if sourceURL.standardizedFileURL == optimizedURL.standardizedFileURL {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：已经指向优化副本。")
        continue
      }

      try writeOptimizedJPEG(from: sourceURL, to: optimizedURL, quality: quality)
      if cancellationToken?.isCancelled == true {
        try? fileManager.removeItem(at: optimizedURL)
        throw CancellationError()
      }
      let optimizedSize = fileByteSize(at: optimizedURL) ?? originalSize

      if optimizedSize < originalSize {
        updatedDraft.attachments[index].sourceFilePath = optimizedURL.path
        updatedDraft.attachments[index].byteSize = optimizedSize
        optimizedCount += 1
        savedBytes += originalSize - optimizedSize
        messages.append("\(attachment.originalFilename)：减少 \(originalSize - optimizedSize) bytes。")
      } else {
        try? fileManager.removeItem(at: optimizedURL)
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：优化后没有变小，保留原图。")
      }
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: optimizedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  public func convertAttachmentsToWebP(
    draft: ArticleDraft,
    destinationDirectory: URL,
    quality: CGFloat = 0.78,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var convertedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard isWebPConvertibleFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
        skippedCount += 1
        continue
      }

      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
      guard originalSize > 0 else {
        skippedCount += 1
        continue
      }

      let webPURL = destinationDirectory
        .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename)).webp")

      if sourceURL.standardizedFileURL == webPURL.standardizedFileURL {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：已经是 WebP 优化副本。")
        continue
      }

      try writeConvertedWebP(
        from: sourceURL,
        to: webPURL,
        quality: quality,
        cancellationToken: cancellationToken
      )
      if cancellationToken?.isCancelled == true {
        try? fileManager.removeItem(at: webPURL)
        throw CancellationError()
      }
      let webPSize = fileByteSize(at: webPURL) ?? originalSize
      let oldPublishPath = attachment.relativePublishPath
      let newPublishPath = pathByReplacingExtension(oldPublishPath, with: "webp")
      let oldRepositoryPath = attachment.repositoryPath
      let newRepositoryPath = pathByReplacingExtension(oldRepositoryPath, with: "webp")
      let newFilename = pathByReplacingExtension(attachment.originalFilename, with: "webp")

      updatedDraft.attachments[index].originalFilename = newFilename
      updatedDraft.attachments[index].relativePublishPath = newPublishPath
      updatedDraft.attachments[index].repositoryPath = newRepositoryPath
      updatedDraft.attachments[index].repositorySHA = nil
      updatedDraft.attachments[index].sourceFilePath = webPURL.path
      updatedDraft.attachments[index].byteSize = webPSize
      updatedDraft.bodyMarkdown = replaceMarkdownImagePath(
        in: updatedDraft.bodyMarkdown,
        oldPath: oldPublishPath,
        newPath: newPublishPath
      )
      convertedCount += 1
      savedBytes += max(0, originalSize - webPSize)

      if webPSize < originalSize {
        messages.append("\(attachment.originalFilename)：已转换为 WebP，减少 \(originalSize - webPSize) bytes。")
      } else {
        messages.append("\(attachment.originalFilename)：已转换为 WebP，体积未减少。")
      }

      if oldRepositoryPath != newRepositoryPath, oldPublishPath == newPublishPath {
        messages.append("\(attachment.originalFilename)：仓库路径已更新为 \(newRepositoryPath)。")
      }
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: convertedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  public func optimizeSVGAttachments(
    draft: ArticleDraft,
    destinationDirectory: URL,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var optimizedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard isSVGFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
        skippedCount += 1
        continue
      }

      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      let originalData = try Data(contentsOf: sourceURL)
      guard
        !originalData.isEmpty,
        let svgText = String(data: originalData, encoding: .utf8)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：不是可优化的 UTF-8 SVG，已跳过。")
        continue
      }

      let optimizedText = optimizedSVGText(svgText)
      let optimizedData = Data(optimizedText.utf8)
      guard optimizedData.count < originalData.count else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：优化后没有变小，保留原 SVG。")
        continue
      }

      let optimizedURL = destinationDirectory
        .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename)).svg")

      if sourceURL.standardizedFileURL == optimizedURL.standardizedFileURL {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：已经指向优化副本。")
        continue
      }

      try? fileManager.removeItem(at: optimizedURL)
      try optimizedData.write(to: optimizedURL, options: .atomic)
      if cancellationToken?.isCancelled == true {
        try? fileManager.removeItem(at: optimizedURL)
        throw CancellationError()
      }

      updatedDraft.attachments[index].sourceFilePath = optimizedURL.path
      updatedDraft.attachments[index].byteSize = Int64(optimizedData.count)
      optimizedCount += 1
      savedBytes += Int64(originalData.count - optimizedData.count)
      messages.append("\(attachment.originalFilename)：SVG 优化减少 \(originalData.count - optimizedData.count) bytes。")
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: optimizedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  public func resizeLargeAttachments(
    draft: ArticleDraft,
    destinationDirectory: URL,
    maxPixelDimension: Int = 1_600,
    quality: CGFloat = 0.82,
    cancellationToken: ImageProcessingCancellationToken? = nil,
    includedAttachmentIDs: Set<UUID>? = nil
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var resizedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var messages: [String] = []

    for index in updatedDraft.attachments.indices {
      try cancellationToken?.throwIfCancelled()
      let attachment = updatedDraft.attachments[index]
      if let includedAttachmentIDs, !includedAttachmentIDs.contains(attachment.id) { continue }
      guard attachment.mediaKind == .image else { continue }
      guard isResizableRasterFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
        skippedCount += 1
        continue
      }

      guard
        let sourceFilePath = attachment.sourceFilePath,
        fileManager.fileExists(atPath: sourceFilePath)
      else {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：源文件不可用，已跳过。")
        continue
      }

      let sourceURL = URL(fileURLWithPath: sourceFilePath)
      guard
        let dimensions = imageDimensions(at: sourceURL),
        max(dimensions.width, dimensions.height) > maxPixelDimension
      else {
        skippedCount += 1
        continue
      }

      let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
      let destinationExtension = URL(fileURLWithPath: attachment.originalFilename).pathExtension.lowercased().nilIfEmpty ?? "jpg"
      let resizedURL = destinationDirectory
        .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename))-resize.\(destinationExtension)")

      if sourceURL.standardizedFileURL == resizedURL.standardizedFileURL {
        skippedCount += 1
        messages.append("\(attachment.originalFilename)：已经指向缩放副本。")
        continue
      }

      try writeResizedImage(
        from: sourceURL,
        to: resizedURL,
        maxPixelDimension: maxPixelDimension,
        quality: quality
      )
      if cancellationToken?.isCancelled == true {
        try? fileManager.removeItem(at: resizedURL)
        throw CancellationError()
      }

      let resizedSize = fileByteSize(at: resizedURL) ?? originalSize
      let resizedDimensions = imageDimensions(at: resizedURL)
      updatedDraft.attachments[index].sourceFilePath = resizedURL.path
      updatedDraft.attachments[index].byteSize = resizedSize
      resizedCount += 1
      savedBytes += max(0, originalSize - resizedSize)

      let dimensionText = resizedDimensions?.displayName ?? "\(maxPixelDimension)px 内"
      messages.append("\(attachment.originalFilename)：已缩放到 \(dimensionText)。")
    }

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: resizedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  public func cropAttachmentToAspectRatio(
    draft: ArticleDraft,
    attachmentID: UUID,
    destinationDirectory: URL,
    aspectWidth: CGFloat = 16,
    aspectHeight: CGFloat = 9,
    quality: CGFloat = 0.86
  ) throws -> ImageOptimizationResult {
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    var updatedDraft = draft
    var messages: [String] = []

    guard let index = updatedDraft.attachments.firstIndex(where: { $0.id == attachmentID }) else {
      return ImageOptimizationResult(
        draft: updatedDraft,
        optimizedCount: 0,
        skippedCount: 1,
        savedBytes: 0,
        messages: ["没有找到要裁剪的图片附件。"]
      )
    }

    let attachment = updatedDraft.attachments[index]
    guard isCroppableRasterFilename(attachment.sourceFilePath ?? attachment.originalFilename) else {
      return ImageOptimizationResult(
        draft: updatedDraft,
        optimizedCount: 0,
        skippedCount: 1,
        savedBytes: 0,
        messages: ["\(attachment.originalFilename)：当前格式不适合直接裁剪。"]
      )
    }

    guard
      let sourceFilePath = attachment.sourceFilePath,
      fileManager.fileExists(atPath: sourceFilePath)
    else {
      return ImageOptimizationResult(
        draft: updatedDraft,
        optimizedCount: 0,
        skippedCount: 1,
        savedBytes: 0,
        messages: ["\(attachment.originalFilename)：源文件不可用，无法裁剪。"]
      )
    }

    let sourceURL = URL(fileURLWithPath: sourceFilePath)
    let originalSize = fileByteSize(at: sourceURL) ?? attachment.byteSize
    let destinationExtension = URL(fileURLWithPath: attachment.originalFilename).pathExtension.lowercased().nilIfEmpty ?? "jpg"
    let croppedURL = destinationDirectory
      .appendingPathComponent("\(attachment.id.uuidString)-\(SlugService.slug(from: attachment.originalFilename))-crop.\(destinationExtension)")

    if sourceURL.standardizedFileURL == croppedURL.standardizedFileURL {
      return ImageOptimizationResult(
        draft: updatedDraft,
        optimizedCount: 0,
        skippedCount: 1,
        savedBytes: 0,
        messages: ["\(attachment.originalFilename)：已经指向裁剪副本。"]
      )
    }

    try writeCroppedImage(
      from: sourceURL,
      to: croppedURL,
      aspectWidth: aspectWidth,
      aspectHeight: aspectHeight,
      quality: quality
    )

    let croppedSize = fileByteSize(at: croppedURL) ?? originalSize
    updatedDraft.attachments[index].sourceFilePath = croppedURL.path
    updatedDraft.attachments[index].byteSize = croppedSize
    let savedBytes = max(0, originalSize - croppedSize)
    messages.append("\(attachment.originalFilename)：已裁剪为 \(Int(aspectWidth)):\(Int(aspectHeight))。")

    return ImageOptimizationResult(
      draft: updatedDraft,
      optimizedCount: 1,
      skippedCount: 0,
      savedBytes: savedBytes,
      messages: messages
    )
  }

  private func fileByteSize(at url: URL) -> Int64? {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else {
      return nil
    }
    return size.int64Value
  }

  private func visibleIssueCount(_ report: ImageWorkbenchReport, severity: PreflightSeverity? = nil) -> Int {
    report.issues.filter { issue in
      issue.title != "还没有图片" && (severity == nil || issue.severity == severity)
    }.count
  }

  private func coverPublishStatus(
    draft: ArticleDraft,
    profile: SiteProfile,
    items: [ImageWorkbenchItem]
  ) -> ImageCoverPublishStatus {
    let frontMatterFieldPath = profile.includeCoverInFrontMatter ? profile.siteKind.coverFrontMatterDisplayPath : nil

    guard profile.includeCoverInFrontMatter else {
      return ImageCoverPublishStatus(state: .disabled, frontMatterFieldPath: nil)
    }

    guard let coverID = draft.coverAttachmentID else {
      return ImageCoverPublishStatus(
        state: draft.isPrivate ? .privateSuppressed : .missingCover,
        frontMatterFieldPath: frontMatterFieldPath
      )
    }

    guard let attachment = draft.attachments.first(where: { $0.id == coverID }) else {
      return ImageCoverPublishStatus(
        state: draft.isPrivate ? .privateSuppressed : .missingAttachment,
        frontMatterFieldPath: frontMatterFieldPath,
        attachmentID: coverID
      )
    }

    let item = items.first(where: { $0.attachmentID == coverID })
    let fileExists = item?.fileExists ?? false
    let baseStatus = ImageCoverPublishStatus(
      state: .ready,
      frontMatterFieldPath: frontMatterFieldPath,
      attachmentID: coverID,
      originalFilename: attachment.originalFilename,
      relativePublishPath: attachment.relativePublishPath,
      repositoryPath: attachment.repositoryPath,
      sourceFilePath: attachment.sourceFilePath,
      fileExists: fileExists
    )

    if draft.isPrivate {
      var status = baseStatus
      status.state = .privateSuppressed
      return status
    }

    if attachment.relativePublishPath.trimmedForPublishing.isEmpty {
      var status = baseStatus
      status.state = .missingPublishPath
      return status
    }

    if !fileExists {
      var status = baseStatus
      status.state = .missingSource
      return status
    }

    return baseStatus
  }

  private func imageDimensions(at url: URL) -> ImageDimensions? {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      return nil
    }

    return ImageDimensions(width: width.intValue, height: height.intValue)
  }

  private func writeOptimizedJPEG(from sourceURL: URL, to destinationURL: URL, quality: CGFloat) throws {
    try? fileManager.removeItem(at: destinationURL)

    guard
      let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImageFromSource(destination, source, 0, options)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  private func writeConvertedWebP(
    from sourceURL: URL,
    to destinationURL: URL,
    quality: CGFloat,
    cancellationToken: ImageProcessingCancellationToken?
  ) throws {
    try? fileManager.removeItem(at: destinationURL)
    try cancellationToken?.throwIfCancelled()

    if !prefersCWebP, Self.supportsImageIOWebPEncoding {
      do {
        try writeConvertedWebPWithImageIO(from: sourceURL, to: destinationURL, quality: quality)
        return
      } catch {
        try? fileManager.removeItem(at: destinationURL)
      }
    }

    if let cwebPURL = cwebPExecutableOverride ?? Self.cwebPExecutableURL {
      try writeConvertedWebPWithCWebP(
        from: sourceURL,
        to: destinationURL,
        quality: quality,
        executableURL: cwebPURL,
        cancellationToken: cancellationToken
      )
      return
    }

    throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
  }

  private func writeConvertedWebPWithImageIO(from sourceURL: URL, to destinationURL: URL, quality: CGFloat) throws {
    guard
      let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.webP.identifier as CFString,
        1,
        nil
      )
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImageFromSource(destination, source, 0, options)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  private func writeConvertedWebPWithCWebP(
    from sourceURL: URL,
    to destinationURL: URL,
    quality: CGFloat,
    executableURL: URL,
    cancellationToken: ImageProcessingCancellationToken?
  ) throws {
    let intermediateURL = destinationURL
      .deletingLastPathComponent()
      .appendingPathComponent("\(UUID().uuidString)-webp-source.png")
    defer {
      try? fileManager.removeItem(at: intermediateURL)
    }
    var completedSuccessfully = false
    defer {
      if !completedSuccessfully {
        try? fileManager.removeItem(at: destinationURL)
      }
    }

    try writePNGIntermediate(from: sourceURL, to: intermediateURL)
    try cancellationToken?.throwIfCancelled()

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "-quiet",
      "-q",
      "\(max(1, min(100, Int((quality * 100).rounded()))))",
      intermediateURL.path,
      "-o",
      destinationURL.path,
    ]

    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    try process.run()

    let deadline = Date().addingTimeInterval(cwebPTimeout)
    while completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
      if cancellationToken?.isCancelled == true {
        terminate(process, waitingOn: completion)
        throw CancellationError()
      }
      if Date() >= deadline {
        terminate(process, waitingOn: completion)
        throw ImageWorkbenchError.externalToolTimedOut("cwebp")
      }
    }

    guard process.terminationStatus == 0,
          fileManager.fileExists(atPath: destinationURL.path)
    else {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
    completedSuccessfully = true
  }

  private func terminate(_ process: Process, waitingOn completion: DispatchSemaphore) {
    guard process.isRunning else { return }
    process.terminate()
    if completion.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
      #if canImport(Darwin)
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
      #endif
      _ = completion.wait(timeout: .now() + .seconds(1))
    }
  }

  private func writePNGIntermediate(from sourceURL: URL, to destinationURL: URL) throws {
    try? fileManager.removeItem(at: destinationURL)

    guard
      let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    CGImageDestinationAddImage(destination, image, nil)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  private func writeResizedImage(
    from sourceURL: URL,
    to destinationURL: URL,
    maxPixelDimension: Int,
    quality: CGFloat
  ) throws {
    try? fileManager.removeItem(at: destinationURL)

    guard
      let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let destinationType = CGImageSourceGetType(source)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let width = image.width
    let height = image.height
    let scale = min(1, CGFloat(maxPixelDimension) / CGFloat(max(width, height)))
    let targetWidth = max(1, Int((CGFloat(width) * scale).rounded()))
    let targetHeight = max(1, Int((CGFloat(height) * scale).rounded()))
    let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

    guard
      let resizedImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, destinationType, 1, nil)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImage(destination, resizedImage, options)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  private func writeCroppedImage(
    from sourceURL: URL,
    to destinationURL: URL,
    aspectWidth: CGFloat,
    aspectHeight: CGFloat,
    quality: CGFloat
  ) throws {
    try? fileManager.removeItem(at: destinationURL)

    guard
      aspectWidth > 0,
      aspectHeight > 0,
      let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let destinationType = CGImageSourceGetType(source)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let sourceWidth = CGFloat(image.width)
    let sourceHeight = CGFloat(image.height)
    let targetAspect = aspectWidth / aspectHeight
    let sourceAspect = sourceWidth / sourceHeight
    let cropRect: CGRect

    if sourceAspect > targetAspect {
      let cropWidth = (sourceHeight * targetAspect).rounded(.down)
      cropRect = CGRect(
        x: ((sourceWidth - cropWidth) / 2).rounded(.down),
        y: 0,
        width: cropWidth,
        height: sourceHeight
      )
    } else {
      let cropHeight = (sourceWidth / targetAspect).rounded(.down)
      cropRect = CGRect(
        x: 0,
        y: ((sourceHeight - cropHeight) / 2).rounded(.down),
        width: sourceWidth,
        height: cropHeight
      )
    }

    guard
      let croppedImage = image.cropping(to: cropRect),
      let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, destinationType, 1, nil)
    else {
      throw ImageWorkbenchError.cannotCreateOptimizedImage(sourceURL.lastPathComponent)
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImage(destination, croppedImage, options)

    if !CGImageDestinationFinalize(destination) {
      throw ImageWorkbenchError.cannotFinalizeOptimizedImage(sourceURL.lastPathComponent)
    }
  }

  private func isJPEGFilename(_ filename: String) -> Bool {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    return ext == "jpg" || ext == "jpeg"
  }

  private func isSVGFilename(_ filename: String) -> Bool {
    URL(fileURLWithPath: filename).pathExtension.lowercased() == "svg"
  }

  private func stableSummaryIssues(
    _ issues: [ImageWorkbenchIssue],
    draftID: UUID
  ) -> [ImageWorkbenchIssue] {
    issues.enumerated().map { offset, issue in
      var stableIssue = issue
      let identity = [
        draftID.uuidString,
        issue.attachmentID?.uuidString ?? "",
        issue.severity.rawValue,
        issue.title,
        issue.message,
        String(offset),
      ].joined(separator: "\u{1F}")
      var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
      bytes[6] = (bytes[6] & 0x0F) | 0x50
      bytes[8] = (bytes[8] & 0x3F) | 0x80
      stableIssue.id = UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
      return stableIssue
    }
  }

  private func isWebPConvertibleFilename(_ filename: String) -> Bool {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "heic", "tif", "tiff", "avif":
      return true
    default:
      return false
    }
  }

  private func isResizableRasterFilename(_ filename: String) -> Bool {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "avif":
      return true
    default:
      return false
    }
  }

  private func isCroppableRasterFilename(_ filename: String) -> Bool {
    isResizableRasterFilename(filename)
  }

  private func pathByReplacingExtension(_ path: String, with newExtension: String) -> String {
    let trimmed = path.trimmedForPublishing
    let namespace = trimmed as NSString
    let basePath = namespace.deletingPathExtension
    guard !basePath.isEmpty else {
      return trimmed
    }
    return basePath + ".\(newExtension)"
  }

  private func optimizedSVGText(_ text: String) -> String {
    var optimized = text
    optimized = optimized.replacingOccurrences(
      of: #"(?s)<!--.*?-->"#,
      with: "",
      options: .regularExpression
    )
    optimized = optimized.replacingOccurrences(
      of: #">\s+<"#,
      with: "><",
      options: .regularExpression
    )
    optimized = optimized
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: "\n")
    return optimized.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func humanizedFilename(_ filename: String) -> String {
    let stem = URL(fileURLWithPath: filename)
      .deletingPathExtension()
      .lastPathComponent
    return stem
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .trimmedForPublishing
      .nilIfEmpty ?? "图片"
  }

  private func localMarkdownImagePathCounts(in markdown: String) -> [String: Int] {
    let pattern = #"!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return [:]
    }

    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    let paths = regex.matches(in: markdown, range: range).compactMap { match -> String? in
      guard let matchRange = Range(match.range(at: 1), in: markdown) else { return nil }
      let path = String(markdown[matchRange])
      guard !path.hasPrefix("http://"), !path.hasPrefix("https://"), !path.hasPrefix("data:") else {
        return nil
      }
      return path
    }
    return paths.reduce(into: [:]) { counts, path in
      counts[path, default: 0] += 1
    }
  }

  private func duplicateCounts(_ values: [String?]) -> [String: Int] {
    values.compactMap { $0 }.reduce(into: [:]) { counts, value in
      counts[value, default: 0] += 1
    }
  }

  private func normalizedPublishPath(_ path: String) -> String? {
    path.trimmedForPublishing.nilIfEmpty
  }

  private func normalizedSourcePath(_ path: String?) -> String? {
    guard let path = path?.trimmedForPublishing.nilIfEmpty else {
      return nil
    }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func replaceEmptyMarkdownAlt(
    in markdown: String,
    imagePath: String,
    altText: String
  ) -> (text: String, replacementCount: Int) {
    let pattern = #"!\[([^\]]*)\]\("#
      + NSRegularExpression.escapedPattern(for: imagePath)
      + #"\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return (markdown, 0)
    }

    var updated = markdown
    var replacementCount = 0
    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    let matches = regex.matches(in: markdown, range: range)

    for match in matches.reversed() {
      guard
        let fullRange = Range(match.range(at: 0), in: updated),
        let altRange = Range(match.range(at: 1), in: updated)
      else {
        continue
      }

      if updated[altRange].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        updated.replaceSubrange(fullRange, with: "![\(altText)](\(imagePath))")
        replacementCount += 1
      }
    }

    return (updated, replacementCount)
  }

  private func replaceMarkdownImagePath(
    in markdown: String,
    oldPath: String,
    newPath: String
  ) -> String {
    guard oldPath != newPath else {
      return markdown
    }
    let pattern = #"(!\[[^\]]*\]\()"#
      + NSRegularExpression.escapedPattern(for: oldPath)
      + #"((?:\s+"[^"]*")?\))"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return markdown
    }

    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return regex.stringByReplacingMatches(
      in: markdown,
      range: range,
      withTemplate: "$1\(newPath)$2"
    )
  }
}
