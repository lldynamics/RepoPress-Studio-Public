import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(Darwin)
  import Darwin
#endif

struct ValidatedImageSource {
  let source: CGImageSource
  let dimensions: ImageDimensions
}
public struct SiteImageWorkbenchService: Sendable {
  public static let maximumSafeInputPixelDimension = 16_384
  public static let maximumSafeInputPixelCount = 64_000_000
  public static let maximumCropWorkingPixelDimension = 4_096

  public typealias AsyncReportOperation =
    @Sendable (ArticleDraft, SiteProfile) async throws -> ImageWorkbenchReport
  public typealias AsyncSiteSummaryOperation =
    @Sendable ([ArticleDraft], SiteProfile) async throws -> ImageWorkbenchSiteSummary

  let fileSystem: SendableFileManager
  let cwebPExecutableOverride: URL?
  let cwebPTimeout: TimeInterval
  let prefersCWebP: Bool
  let imagePrivacySanitizer: ImagePrivacySanitizingService
  private let asyncReportOperation: AsyncReportOperation?
  private let asyncSiteSummaryOperation: AsyncSiteSummaryOperation?

  var fileManager: FileManager { fileSystem.value }

  public static var supportsWebPEncoding: Bool {
    supportsImageIOWebPEncoding || cwebPExecutableURL != nil
  }

  static var supportsImageIOWebPEncoding: Bool {
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
      let image = context.makeImage()
    else {
      return false
    }

    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
  }

  static var cwebPExecutableURL: URL? {
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
    imagePrivacySanitizer: ImagePrivacySanitizingService = ImagePrivacySanitizingService(),
    asyncReportOperation: AsyncReportOperation? = nil,
    asyncSiteSummaryOperation: AsyncSiteSummaryOperation? = nil
  ) {
    self.fileSystem = SendableFileManager(fileManager)
    self.cwebPExecutableOverride = cwebPExecutableURL
    self.cwebPTimeout = max(0.1, cwebPTimeout)
    self.prefersCWebP = prefersCWebP
    self.imagePrivacySanitizer = imagePrivacySanitizer
    self.asyncReportOperation = asyncReportOperation
    self.asyncSiteSummaryOperation = asyncSiteSummaryOperation
  }

  /// Performs file-backed image inspection away from the caller's actor.
  /// The synchronous API remains available for explicit publishing and AI actions.
  public func reportAsync(draft: ArticleDraft, profile: SiteProfile) async throws
    -> ImageWorkbenchReport
  {
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
    makeReport(draft: draft, profile: profile, cancellationCheck: {})
  }

  private func makeReport(
    draft: ArticleDraft,
    profile: SiteProfile,
    cancellationCheck: () throws -> Void
  ) rethrows -> ImageWorkbenchReport {
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
      let canConvertToWebP =
        fileExists
        && isWebPConvertibleFilename(sourceURL?.lastPathComponent ?? attachment.originalFilename)
      let canOptimizeSVG =
        fileExists && isSVGFilename(sourceURL?.lastPathComponent ?? attachment.originalFilename)
        && actualByteSize > 0
      let canResizeImage =
        fileExists
        && isResizableRasterFilename(sourceURL?.lastPathComponent ?? attachment.originalFilename)
        && (dimensions.map { max($0.width, $0.height) > 1_600 } ?? false)
      let privacyStatus: ImagePrivacyStatus
      if let sourceURL, fileExists {
        do {
          privacyStatus =
            try imagePrivacySanitizer.inspect(at: sourceURL).requiresSanitization
            ? .sensitive
            : .clean
        } catch ImagePrivacySanitizingError.unsupportedImage(_) {
          privacyStatus = .unsupported
        } catch {
          privacyStatus = .unverified
        }
      } else {
        privacyStatus = .unverified
      }
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
            kind: .missingAltText,
            title: CoreL10n.text("缺少 alt 文本"),
            message: CoreL10n.format("%@ 需要可发布的替代文本。", attachment.originalFilename),
            attachmentID: attachment.id
          )
        )
      }

      if missingCaption {
        issues.append(
          ImageWorkbenchIssue(
            severity: .info,
            kind: .missingCaption,
            title: CoreL10n.text("缺少 caption"),
            message: CoreL10n.format("%@ 还没有图片说明。", attachment.originalFilename),
            attachmentID: attachment.id
          )
        )
      }

      if privacyStatus == .sensitive {
        issues.append(
          ImageWorkbenchIssue(
            severity: .warning,
            kind: .sensitiveMetadata,
            title: CoreL10n.text("图片包含隐私元数据"),
            message: CoreL10n.format(
              "%@ 包含定位、设备、作者或其他可识别元数据，发布前应清理。",
              attachment.originalFilename
            ),
            attachmentID: attachment.id
          )
        )
      }

      if !fileExists {
        issues.append(
          ImageWorkbenchIssue(
            severity: .error,
            kind: .missingSource,
            title: CoreL10n.text("源文件不可用"),
            message: CoreL10n.format("%@ 的本地源文件不存在，发布时无法复制。", attachment.originalFilename),
            attachmentID: attachment.id
          )
        )
      }

      if attachment.relativePublishPath.trimmedForPublishing.isEmpty {
        issues.append(
          ImageWorkbenchIssue(
            severity: .error,
            kind: .missingPublishPath,
            title: CoreL10n.text("发布引用为空"),
            message: CoreL10n.format("%@ 缺少 Markdown 中可用的公开图片路径。", attachment.originalFilename),
            attachmentID: attachment.id
          )
        )
      }

      if attachment.repositoryPath.contains("..") {
        issues.append(
          ImageWorkbenchIssue(
            severity: .error,
            kind: .unsafeRepositoryPath,
            title: CoreL10n.text("仓库路径不安全"),
            message: CoreL10n.format("%@ 不能包含 ..。", attachment.repositoryPath),
            attachmentID: attachment.id
          )
        )
      }

      if actualByteSize > 1_500_000 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .warning,
            kind: .largeFile,
            title: CoreL10n.text("图片体积偏大"),
            message: CoreL10n.format("%@ 超过 1.5 MB，建议发布前压缩。", attachment.originalFilename),
            attachmentID: attachment.id
          )
        )
      }

      if let dimensions, max(dimensions.width, dimensions.height) > 2_400 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .info,
            kind: .largeDimensions,
            title: CoreL10n.text("尺寸偏大"),
            message: CoreL10n.format(
              "%@ 为 %@，确认是否需要这么大的发布尺寸。",
              attachment.originalFilename,
              dimensions.displayName
            ),
            attachmentID: attachment.id
          )
        )
      }

      if !isReferenced && !isCover {
        issues.append(
          ImageWorkbenchIssue(
            severity: .info,
            kind: .unreferencedAttachment,
            title: CoreL10n.text("正文未引用"),
            message: CoreL10n.format("%@ 不在正文 Markdown 中，也不是封面图。", attachment.originalFilename),
            attachmentID: attachment.id
          )
        )
      }

      if duplicatePublishCount > 1 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .warning,
            kind: .duplicatePublishPath,
            title: CoreL10n.text("图片发布路径重复"),
            message: CoreL10n.format(
              "%@ 被 %d 个附件共用，发布时可能覆盖或重复引用同一张图片。",
              attachment.relativePublishPath,
              duplicatePublishCount
            ),
            attachmentID: attachment.id
          )
        )
      }

      if duplicateSourceCount > 1 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .warning,
            kind: .duplicateSource,
            title: CoreL10n.text("源图重复使用"),
            message: CoreL10n.format(
              "%@ 与其他附件指向同一个本地源文件，确认是否需要合并引用。",
              attachment.originalFilename
            ),
            attachmentID: attachment.id
          )
        )
      }

      if duplicateMarkdownCount > 1 {
        issues.append(
          ImageWorkbenchIssue(
            severity: .info,
            kind: .duplicateMarkdownReference,
            title: CoreL10n.text("正文重复引用图片"),
            message: CoreL10n.format(
              "%@ 在正文中出现 %d 次，确认是否为有意重复。",
              attachment.relativePublishPath,
              duplicateMarkdownCount
            ),
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
        privacyStatus: privacyStatus,
        duplicateReferenceCount: duplicateReferenceCount
      )
    }

    if profile.includeCoverInFrontMatter, let coverID = draft.coverAttachmentID {
      if !draft.attachments.contains(where: { $0.id == coverID }) {
        issues.append(
          ImageWorkbenchIssue(
            severity: .error,
            kind: .missingCoverAttachment,
            title: CoreL10n.text("封面附件丢失"),
            message: CoreL10n.text("Front Matter 指向的封面图片不在当前附件列表中。"),
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
          kind: .unregisteredMarkdownImage,
          title: CoreL10n.text("正文图片未登记"),
          message: CoreL10n.format("%@ 在正文中使用，但不在附件列表里。", markdownPath),
          relatedValue: markdownPath
        )
      )
    }

    for (markdownPath, count) in markdownImagePathCounts
    where count > 1 && !registeredPublishPaths.contains(markdownPath) {
      issues.append(
        ImageWorkbenchIssue(
          severity: .info,
          kind: .duplicateMarkdownReference,
          title: CoreL10n.text("正文重复引用图片"),
          message: CoreL10n.format("%@ 在正文中出现 %d 次，但还没有登记为图片附件。", markdownPath, count),
          relatedValue: markdownPath
        )
      )
    }

    if items.isEmpty {
      issues.append(
        ImageWorkbenchIssue(
          severity: .info,
          kind: .noImages,
          title: CoreL10n.text("还没有图片"),
          message: CoreL10n.text("当前文章没有图片附件。")
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
    let itemsByID = Dictionary(
      uniqueKeysWithValues: currentReport.items.map { ($0.attachmentID, $0) })
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
    let suggestionsByAttachmentID = Dictionary(
      uniqueKeysWithValues: suggestions.map { ($0.attachmentID, $0) })
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

      let markdownAlt =
        updatedDraft.attachments[index].altText.trimmedForPublishing.nilIfEmpty ?? suggestedAlt
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

  public func siteSummary(drafts: [ArticleDraft], profile: SiteProfile) -> ImageWorkbenchSiteSummary
  {
    makeSiteSummary(drafts: drafts, profile: profile, cancellationCheck: {})
  }

  private func makeSiteSummary(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    cancellationCheck: () throws -> Void
  ) rethrows -> ImageWorkbenchSiteSummary {
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
        !includedAttachmentIDs.contains(updatedDraft.attachments[index].id)
      {
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
}
