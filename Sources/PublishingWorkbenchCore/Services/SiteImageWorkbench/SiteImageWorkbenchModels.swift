import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageDimensions: Codable, Hashable, Sendable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  public var displayName: String {
    "\(width)x\(height)"
  }
}

public struct AIImageTextGenerationAvailabilityPresentation: Equatable, Sendable {
  public var isEnabled: Bool
  public var unavailableReason: String?

  public init(isEnabled: Bool, unavailableReason: String? = nil) {
    self.isEnabled = isEnabled
    self.unavailableReason = unavailableReason
  }
}

public enum AIImageTextGenerationAvailabilityService {
  public static func presentation(
    targetCount: Int,
    isGenerating: Bool,
    aiProviderConfig: AIProviderConfig,
    aiTokenAvailability: KeychainTokenAvailability
  ) -> AIImageTextGenerationAvailabilityPresentation {
    if isGenerating {
      return AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "AI 正在生成图片文案"
      )
    }

    if targetCount <= 0 {
      return AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "当前文章没有缺少 alt/caption 的图片"
      )
    }

    if aiProviderConfig.requiresAPIKey,
       let accessFailureMessage = aiTokenAvailability.accessFailureMessage {
      return AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: CoreL10n.format(
          "AI Keychain 读取失败：%@",
          accessFailureMessage
        )
      )
    }

    if aiProviderConfig.requiresAPIKey && !aiTokenAvailability.hasToken {
      return AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "需要先启用 AI"
      )
    }

    return AIImageTextGenerationAvailabilityPresentation(isEnabled: true)
  }
}

public enum ImageWorkbenchIssueKind: String, Codable, Hashable, Sendable {
  case missingAltText
  case missingCaption
  case missingSource
  case missingPublishPath
  case unsafeRepositoryPath
  case largeFile
  case largeDimensions
  case unreferencedAttachment
  case duplicatePublishPath
  case duplicateSource
  case duplicateMarkdownReference
  case missingCoverAttachment
  case unregisteredMarkdownImage
  case noImages
  case other

  fileprivate var preflightCategory: PreflightIssueCategory? {
    switch self {
    case .missingAltText:
      return .missingMediaAlt
    case .missingPublishPath:
      return .missingMediaPublishPath
    case .unsafeRepositoryPath:
      return .unsafeMediaRepositoryPath
    case .unregisteredMarkdownImage:
      return .unregisteredBodyImage
    default:
      return nil
    }
  }
}

public struct ImageWorkbenchIssue: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var severity: PreflightSeverity
  public var kind: ImageWorkbenchIssueKind
  public var title: String
  public var message: String
  public var attachmentID: UUID?
  public var relatedValue: String?

  public init(
    id: UUID = UUID(),
    severity: PreflightSeverity,
    kind: ImageWorkbenchIssueKind = .other,
    title: String,
    message: String,
    attachmentID: UUID? = nil,
    relatedValue: String? = nil
  ) {
    self.id = id
    self.severity = severity
    self.kind = kind
    self.title = title
    self.message = message
    self.attachmentID = attachmentID
    self.relatedValue = relatedValue
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case severity
    case kind
    case title
    case message
    case attachmentID
    case relatedValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    severity = try container.decode(PreflightSeverity.self, forKey: .severity)
    kind = try container.decodeIfPresent(ImageWorkbenchIssueKind.self, forKey: .kind) ?? .other
    title = try container.decode(String.self, forKey: .title)
    message = try container.decode(String.self, forKey: .message)
    attachmentID = try container.decodeIfPresent(UUID.self, forKey: .attachmentID)
    relatedValue = try container.decodeIfPresent(String.self, forKey: .relatedValue)
  }
}

public extension ImageWorkbenchIssue {
  func isCovered(by preflightIssues: [PreflightIssue]) -> Bool {
    guard let category = kind.preflightCategory else { return false }
    return preflightIssues.contains { $0.category == category }
  }

  /// Adapts resource findings to the article-wide check queue. The neutral
  /// no-images state is inventory information, not an article problem.
  var preflightIssue: PreflightIssue? {
    guard kind != .noImages else { return nil }
    let field: String?
    switch kind {
    case .unregisteredMarkdownImage:
      field = "body"
    case .duplicateMarkdownReference:
      field = attachmentID == nil ? "body" : "attachments"
    case .noImages:
      field = nil
    case .other:
      field = attachmentID == nil ? "body" : "attachments"
    default:
      field = "attachments"
    }
    return PreflightIssue(
      id: id,
      severity: severity,
      title: title,
      message: message,
      field: field,
      category: kind.preflightCategory,
      relatedValue: relatedValue
    )
  }
}

public struct ImageWorkbenchItem: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { attachmentID }

  public var attachmentID: UUID
  public var originalFilename: String
  public var relativePublishPath: String
  public var repositoryPath: String
  public var sourceFilePath: String?
  public var byteSize: Int64
  public var dimensions: ImageDimensions?
  public var fileExists: Bool
  public var isCover: Bool
  public var isReferencedInMarkdown: Bool
  public var missingAltText: Bool
  public var missingCaption: Bool
  public var canOptimizeJPEG: Bool
  public var canConvertToWebP: Bool
  public var canOptimizeSVG: Bool
  public var canResizeImage: Bool
  public var duplicateReferenceCount: Int

  public init(
    attachmentID: UUID,
    originalFilename: String,
    relativePublishPath: String,
    repositoryPath: String,
    sourceFilePath: String?,
    byteSize: Int64,
    dimensions: ImageDimensions?,
    fileExists: Bool,
    isCover: Bool,
    isReferencedInMarkdown: Bool,
    missingAltText: Bool,
    missingCaption: Bool,
    canOptimizeJPEG: Bool,
    canConvertToWebP: Bool = false,
    canOptimizeSVG: Bool = false,
    canResizeImage: Bool = false,
    duplicateReferenceCount: Int = 0
  ) {
    self.attachmentID = attachmentID
    self.originalFilename = originalFilename
    self.relativePublishPath = relativePublishPath
    self.repositoryPath = repositoryPath
    self.sourceFilePath = sourceFilePath
    self.byteSize = byteSize
    self.dimensions = dimensions
    self.fileExists = fileExists
    self.isCover = isCover
    self.isReferencedInMarkdown = isReferencedInMarkdown
    self.missingAltText = missingAltText
    self.missingCaption = missingCaption
    self.canOptimizeJPEG = canOptimizeJPEG
    self.canConvertToWebP = canConvertToWebP
    self.canOptimizeSVG = canOptimizeSVG
    self.canResizeImage = canResizeImage
    self.duplicateReferenceCount = duplicateReferenceCount
  }
}

public enum ImageCoverPublishState: String, Codable, Sendable {
  case ready
  case disabled
  case privateSuppressed
  case missingCover
  case missingAttachment
  case missingPublishPath
  case missingSource

  public var displayName: String {
    switch self {
    case .ready:
      return "封面可发布"
    case .disabled:
      return "未写入 Front Matter"
    case .privateSuppressed:
      return "私密文章已抑制"
    case .missingCover:
      return "未设置封面"
    case .missingAttachment:
      return "封面附件丢失"
    case .missingPublishPath:
      return "封面发布路径为空"
    case .missingSource:
      return "封面源图缺失"
    }
  }
}

public struct ImageCoverPublishStatus: Codable, Hashable, Sendable {
  public var state: ImageCoverPublishState
  public var frontMatterFieldPath: String?
  public var attachmentID: UUID?
  public var originalFilename: String?
  public var relativePublishPath: String?
  public var repositoryPath: String?
  public var sourceFilePath: String?
  public var fileExists: Bool

  public init(
    state: ImageCoverPublishState,
    frontMatterFieldPath: String?,
    attachmentID: UUID? = nil,
    originalFilename: String? = nil,
    relativePublishPath: String? = nil,
    repositoryPath: String? = nil,
    sourceFilePath: String? = nil,
    fileExists: Bool = false
  ) {
    self.state = state
    self.frontMatterFieldPath = frontMatterFieldPath
    self.attachmentID = attachmentID
    self.originalFilename = originalFilename
    self.relativePublishPath = relativePublishPath
    self.repositoryPath = repositoryPath
    self.sourceFilePath = sourceFilePath
    self.fileExists = fileExists
  }

  public var writesFrontMatter: Bool {
    state == .ready
  }
}

public struct ImageWorkbenchReport: Codable, Hashable, Sendable {
  public var draftID: UUID
  public var generatedAt: Date
  public var items: [ImageWorkbenchItem]
  public var coverStatus: ImageCoverPublishStatus
  public var issues: [ImageWorkbenchIssue]

  public init(
    draftID: UUID,
    generatedAt: Date = Date(),
    items: [ImageWorkbenchItem],
    coverStatus: ImageCoverPublishStatus,
    issues: [ImageWorkbenchIssue]
  ) {
    self.draftID = draftID
    self.generatedAt = generatedAt
    self.items = items
    self.coverStatus = coverStatus
    self.issues = issues
  }

  public var totalByteSize: Int64 {
    items.reduce(0) { $0 + max(0, $1.byteSize) }
  }

  public var missingAltTextCount: Int {
    items.filter(\.missingAltText).count
  }

  public var missingCaptionCount: Int {
    items.filter(\.missingCaption).count
  }

  public var missingSourceCount: Int {
    items.filter { !$0.fileExists }.count
  }

  public var optimizableJPEGCount: Int {
    items.filter(\.canOptimizeJPEG).count
  }

  public var webPConvertibleCount: Int {
    items.filter(\.canConvertToWebP).count
  }

  public var optimizableSVGCount: Int {
    items.filter(\.canOptimizeSVG).count
  }

  public var resizableImageCount: Int {
    items.filter(\.canResizeImage).count
  }

  public var duplicateImageCount: Int {
    items.filter { $0.duplicateReferenceCount > 0 }.count
  }
}

public struct ImageWorkbenchDraftSummary: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { draftID }

  public var draftID: UUID
  public var draftTitle: String
  public var imageCount: Int
  public var issueCount: Int
  public var errorCount: Int
  public var warningCount: Int
  public var missingAltTextCount: Int
  public var missingCaptionCount: Int
  public var missingSourceCount: Int
  public var optimizableJPEGCount: Int
  public var webPConvertibleCount: Int
  public var optimizableSVGCount: Int
  public var resizableImageCount: Int
  public var duplicateImageCount: Int
  public var items: [ImageWorkbenchItem]
  public var issues: [ImageWorkbenchIssue]

  public init(
    draftID: UUID,
    draftTitle: String,
    imageCount: Int,
    issueCount: Int,
    errorCount: Int,
    warningCount: Int,
    missingAltTextCount: Int,
    missingCaptionCount: Int,
    missingSourceCount: Int,
    optimizableJPEGCount: Int,
    webPConvertibleCount: Int = 0,
    optimizableSVGCount: Int = 0,
    resizableImageCount: Int = 0,
    duplicateImageCount: Int = 0,
    items: [ImageWorkbenchItem] = [],
    issues: [ImageWorkbenchIssue] = []
  ) {
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.imageCount = imageCount
    self.issueCount = issueCount
    self.errorCount = errorCount
    self.warningCount = warningCount
    self.missingAltTextCount = missingAltTextCount
    self.missingCaptionCount = missingCaptionCount
    self.missingSourceCount = missingSourceCount
    self.optimizableJPEGCount = optimizableJPEGCount
    self.webPConvertibleCount = webPConvertibleCount
    self.optimizableSVGCount = optimizableSVGCount
    self.resizableImageCount = resizableImageCount
    self.duplicateImageCount = duplicateImageCount
    self.items = items
    self.issues = issues
  }
}

public struct ImageWorkbenchSiteSummary: Codable, Hashable, Sendable {
  public var draftCount: Int
  public var imageCount: Int
  public var totalByteSize: Int64
  public var issueCount: Int
  public var errorCount: Int
  public var warningCount: Int
  public var missingAltTextCount: Int
  public var missingCaptionCount: Int
  public var missingSourceCount: Int
  public var optimizableJPEGCount: Int
  public var webPConvertibleCount: Int
  public var optimizableSVGCount: Int
  public var resizableImageCount: Int
  public var duplicateImageCount: Int
  public var draftSummaries: [ImageWorkbenchDraftSummary]

  public init(
    draftCount: Int,
    imageCount: Int,
    totalByteSize: Int64,
    issueCount: Int,
    errorCount: Int,
    warningCount: Int,
    missingAltTextCount: Int,
    missingCaptionCount: Int,
    missingSourceCount: Int,
    optimizableJPEGCount: Int,
    webPConvertibleCount: Int = 0,
    optimizableSVGCount: Int = 0,
    resizableImageCount: Int = 0,
    duplicateImageCount: Int = 0,
    draftSummaries: [ImageWorkbenchDraftSummary]
  ) {
    self.draftCount = draftCount
    self.imageCount = imageCount
    self.totalByteSize = totalByteSize
    self.issueCount = issueCount
    self.errorCount = errorCount
    self.warningCount = warningCount
    self.missingAltTextCount = missingAltTextCount
    self.missingCaptionCount = missingCaptionCount
    self.missingSourceCount = missingSourceCount
    self.optimizableJPEGCount = optimizableJPEGCount
    self.webPConvertibleCount = webPConvertibleCount
    self.optimizableSVGCount = optimizableSVGCount
    self.resizableImageCount = resizableImageCount
    self.duplicateImageCount = duplicateImageCount
    self.draftSummaries = draftSummaries
  }
}

public struct ImageMetadataFillResult: Sendable {
  public var draft: ArticleDraft
  public var filledAltTextCount: Int
  public var filledCaptionCount: Int
  public var updatedMarkdownReferenceCount: Int

  public init(
    draft: ArticleDraft,
    filledAltTextCount: Int,
    filledCaptionCount: Int,
    updatedMarkdownReferenceCount: Int
  ) {
    self.draft = draft
    self.filledAltTextCount = filledAltTextCount
    self.filledCaptionCount = filledCaptionCount
    self.updatedMarkdownReferenceCount = updatedMarkdownReferenceCount
  }
}

public struct ImageOptimizationResult: Sendable {
  public var draft: ArticleDraft
  public var optimizedCount: Int
  public var skippedCount: Int
  public var savedBytes: Int64
  public var messages: [String]

  public init(
    draft: ArticleDraft,
    optimizedCount: Int,
    skippedCount: Int,
    savedBytes: Int64,
    messages: [String]
  ) {
    self.draft = draft
    self.optimizedCount = optimizedCount
    self.skippedCount = skippedCount
    self.savedBytes = savedBytes
    self.messages = messages
  }
}

public struct ImageTextSuggestionApplyResult: Sendable {
  public var draft: ArticleDraft
  public var appliedAltTextCount: Int
  public var appliedCaptionCount: Int
  public var updatedMarkdownReferenceCount: Int

  public init(
    draft: ArticleDraft,
    appliedAltTextCount: Int,
    appliedCaptionCount: Int,
    updatedMarkdownReferenceCount: Int
  ) {
    self.draft = draft
    self.appliedAltTextCount = appliedAltTextCount
    self.appliedCaptionCount = appliedCaptionCount
    self.updatedMarkdownReferenceCount = updatedMarkdownReferenceCount
  }

  public var changedCount: Int {
    appliedAltTextCount + appliedCaptionCount + updatedMarkdownReferenceCount
  }
}

public enum ImageWorkbenchError: LocalizedError {
  case cannotCreateOptimizedImage(String)
  case cannotFinalizeOptimizedImage(String)
  case unsafeImageDimensions(filename: String, width: Int, height: Int)
  case externalToolTimedOut(String)

  public var errorDescription: String? {
    switch self {
    case .cannotCreateOptimizedImage(let filename):
      return "无法创建优化图片：\(filename)"
    case .cannotFinalizeOptimizedImage(let filename):
      return "无法写入优化图片：\(filename)"
    case .unsafeImageDimensions(let filename, let width, let height):
      return "图片尺寸超过安全处理上限：\(filename)（\(width) × \(height)）"
    case .externalToolTimedOut(let tool):
      return "\(tool) 执行超时，已停止。"
    }
  }
}
