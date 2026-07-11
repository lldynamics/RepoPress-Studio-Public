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

    if aiProviderConfig.requiresAPIKey && !aiTokenAvailability.hasToken {
      return AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "需要先启用 AI"
      )
    }

    return AIImageTextGenerationAvailabilityPresentation(isEnabled: true)
  }
}

public struct ImageWorkbenchIssue: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var severity: PreflightSeverity
  public var title: String
  public var message: String
  public var attachmentID: UUID?

  public init(
    id: UUID = UUID(),
    severity: PreflightSeverity,
    title: String,
    message: String,
    attachmentID: UUID? = nil
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.message = message
    self.attachmentID = attachmentID
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
    duplicateImageCount: Int = 0
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
  case externalToolTimedOut(String)

  public var errorDescription: String? {
    switch self {
    case .cannotCreateOptimizedImage(let filename):
      return "无法创建优化图片：\(filename)"
    case .cannotFinalizeOptimizedImage(let filename):
      return "无法写入优化图片：\(filename)"
    case .externalToolTimedOut(let tool):
      return "\(tool) 执行超时，已停止。"
    }
  }
}
