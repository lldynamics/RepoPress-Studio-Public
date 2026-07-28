import CoreGraphics
import Foundation
import ImageIO

public enum SEOSocialPreviewCardKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case search
  case openGraph
  case twitter

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .search:
      return "搜索结果"
    case .openGraph:
      return "Open Graph"
    case .twitter:
      return "Twitter/X"
    }
  }

  public var systemImage: String {
    switch self {
    case .search:
      return "magnifyingglass"
    case .openGraph:
      return "link"
    case .twitter:
      return "bubble.left.and.text.bubble.right"
    }
  }
}
public struct SEOSocialPreviewCard: Identifiable, Codable, Hashable, Sendable {
  public var id: SEOSocialPreviewCardKind { kind }
  public var kind: SEOSocialPreviewCardKind
  public var title: String
  public var description: String
  public var urlText: String
  public var imagePath: String?
  public var imageAltText: String?
  public var imageDimensions: ImageDimensions?
  public var siteName: String
  public var titleCharacterLimit: Int
  public var descriptionCharacterLimit: Int
  public var imageAspectRatio: String?
  public var imageGuidance: String

  public init(
    kind: SEOSocialPreviewCardKind,
    title: String,
    description: String,
    urlText: String,
    imagePath: String?,
    imageAltText: String?,
    imageDimensions: ImageDimensions? = nil,
    siteName: String,
    titleCharacterLimit: Int? = nil,
    descriptionCharacterLimit: Int? = nil,
    imageAspectRatio: String? = nil,
    imageGuidance: String? = nil
  ) {
    let defaults = Self.defaults(for: kind)
    self.kind = kind
    self.title = title
    self.description = description
    self.urlText = urlText
    self.imagePath = imagePath
    self.imageAltText = imageAltText
    self.imageDimensions = imageDimensions
    self.siteName = siteName
    self.titleCharacterLimit = titleCharacterLimit ?? defaults.titleCharacterLimit
    self.descriptionCharacterLimit = descriptionCharacterLimit ?? defaults.descriptionCharacterLimit
    self.imageAspectRatio = imageAspectRatio ?? defaults.imageAspectRatio
    self.imageGuidance = imageGuidance ?? defaults.imageGuidance
  }

  public var titleBudgetText: String {
    "\(title.count)/\(titleCharacterLimit)"
  }

  public var descriptionBudgetText: String {
    "\(description.count)/\(descriptionCharacterLimit)"
  }

  public var isTitleWithinBudget: Bool {
    title.count <= titleCharacterLimit
  }

  public var isDescriptionWithinBudget: Bool {
    description.count <= descriptionCharacterLimit
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case title
    case description
    case urlText
    case imagePath
    case imageAltText
    case imageDimensions
    case siteName
    case titleCharacterLimit
    case descriptionCharacterLimit
    case imageAspectRatio
    case imageGuidance
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(SEOSocialPreviewCardKind.self, forKey: .kind)
    let defaults = Self.defaults(for: kind)
    self.kind = kind
    title = try container.decode(String.self, forKey: .title)
    description = try container.decode(String.self, forKey: .description)
    urlText = try container.decode(String.self, forKey: .urlText)
    imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
    imageAltText = try container.decodeIfPresent(String.self, forKey: .imageAltText)
    imageDimensions = try container.decodeIfPresent(ImageDimensions.self, forKey: .imageDimensions)
    siteName = try container.decode(String.self, forKey: .siteName)
    titleCharacterLimit = try container.decodeIfPresent(Int.self, forKey: .titleCharacterLimit) ?? defaults.titleCharacterLimit
    descriptionCharacterLimit = try container.decodeIfPresent(Int.self, forKey: .descriptionCharacterLimit) ?? defaults.descriptionCharacterLimit
    imageAspectRatio = try container.decodeIfPresent(String.self, forKey: .imageAspectRatio) ?? defaults.imageAspectRatio
    imageGuidance = try container.decodeIfPresent(String.self, forKey: .imageGuidance) ?? defaults.imageGuidance
  }

  private static func defaults(
    for kind: SEOSocialPreviewCardKind
  ) -> (titleCharacterLimit: Int, descriptionCharacterLimit: Int, imageAspectRatio: String?, imageGuidance: String) {
    switch kind {
    case .search:
      return (60, 160, nil, "搜索结果通常不展示社交图。")
    case .openGraph:
      return (60, 200, "1.91:1", "建议 1200x630，适合链接分享大图。")
    case .twitter:
      return (70, 200, "1.91:1", "summary_large_image 建议 1200x628。")
    }
  }
}

public struct SEOSocialPreviewMetaTag: Identifiable, Codable, Hashable, Sendable {
  public var id: String { "\(scope.rawValue):\(property):\(content)" }
  public var scope: SEOSocialPreviewCardKind
  public var property: String
  public var content: String
  public var isRequired: Bool

  public init(
    scope: SEOSocialPreviewCardKind,
    property: String,
    content: String,
    isRequired: Bool = true
  ) {
    self.scope = scope
    self.property = property
    self.content = content
    self.isRequired = isRequired
  }
}

public extension SEOSocialPreviewMetaTag {
  var htmlElement: String {
    let key = scope == .openGraph ? "property" : "name"
    return "<meta \(key)=\"\(htmlEscaped(property))\" content=\"\(htmlEscaped(content))\">"
  }

  private func htmlEscaped(_ value: String) -> String {
    MarkupEscaping.htmlDoubleQuotedAttribute(value)
  }
}

public extension Array where Element == SEOSocialPreviewMetaTag {
  var htmlBlock: String {
    map(\.htmlElement).joined(separator: "\n")
  }
}

public enum SEOSocialPreviewReadinessStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case ready
  case warning
  case missing

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .ready:
      return "可发布"
    case .warning:
      return "需确认"
    case .missing:
      return "缺字段"
    }
  }

  public var systemImage: String {
    switch self {
    case .ready:
      return "checkmark.seal"
    case .warning:
      return "exclamationmark.triangle"
    case .missing:
      return "xmark.octagon"
    }
  }
}

public struct SEOSocialPreviewPlatformReadiness: Identifiable, Codable, Hashable, Sendable {
  public var id: SEOSocialPreviewCardKind { kind }
  public var kind: SEOSocialPreviewCardKind
  public var status: SEOSocialPreviewReadinessStatus
  public var title: String
  public var message: String
  public var missingRequiredProperties: [String]
  public var warningMessages: [String]
  public var copyableMetaTags: [SEOSocialPreviewMetaTag]

  public init(
    kind: SEOSocialPreviewCardKind,
    status: SEOSocialPreviewReadinessStatus,
    title: String,
    message: String,
    missingRequiredProperties: [String] = [],
    warningMessages: [String] = [],
    copyableMetaTags: [SEOSocialPreviewMetaTag] = []
  ) {
    self.kind = kind
    self.status = status
    self.title = title
    self.message = message
    self.missingRequiredProperties = missingRequiredProperties
    self.warningMessages = warningMessages
    self.copyableMetaTags = copyableMetaTags
  }
}

public struct SEOSocialShareCopyItem: Identifiable, Codable, Hashable, Sendable {
  public var id: SEOSocialPreviewCardKind { kind }
  public var kind: SEOSocialPreviewCardKind
  public var title: String
  public var body: String
  public var urlText: String
  public var imagePath: String?
  public var imageURLText: String?
  public var hashtags: [String]

  public init(
    kind: SEOSocialPreviewCardKind,
    title: String,
    body: String,
    urlText: String,
    imagePath: String?,
    imageURLText: String? = nil,
    hashtags: [String] = []
  ) {
    self.kind = kind
    self.title = title
    self.body = body
    self.urlText = urlText
    self.imagePath = imagePath
    self.imageURLText = imageURLText
    self.hashtags = hashtags
  }

  public var hashtagText: String {
    hashtags.map { "#\($0)" }.joined(separator: " ")
  }

  public var clipboardText: String {
    [
      title.nilIfEmpty,
      body.nilIfEmpty,
      urlText.nilIfEmpty,
      hashtagText.nilIfEmpty,
    ]
      .compactMap { $0 }
      .joined(separator: "\n\n")
  }
}

public enum SEOSocialPreviewDebugPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
  case facebookSharingDebugger
  case linkedinPostInspector
  case xShareIntent
  case xCardValidator

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .facebookSharingDebugger:
      return "Facebook Sharing Debugger"
    case .linkedinPostInspector:
      return "LinkedIn Post Inspector"
    case .xShareIntent:
      return "X 分享预览"
    case .xCardValidator:
      return "X Card Validator"
    }
  }

  public var purpose: String {
    switch self {
    case .facebookSharingDebugger:
      return "刷新 Open Graph 抓取缓存并检查分享卡片字段。"
    case .linkedinPostInspector:
      return "检查 LinkedIn 抓取到的标题、摘要和封面。"
    case .xShareIntent:
      return "用真实分享入口预览发布文案和链接。"
    case .xCardValidator:
      return "打开 X 卡片验证器，发布后粘贴 URL 复核。"
    }
  }

  public var systemImage: String {
    switch self {
    case .facebookSharingDebugger:
      return "f.square"
    case .linkedinPostInspector:
      return "link.badge.plus"
    case .xShareIntent:
      return "bubble.left.and.text.bubble.right"
    case .xCardValidator:
      return "checkmark.shield"
    }
  }
}

public struct SEOSocialPreviewDebugLink: Identifiable, Codable, Hashable, Sendable {
  public var id: SEOSocialPreviewDebugPlatform { platform }
  public var platform: SEOSocialPreviewDebugPlatform
  public var urlText: String

  public init(platform: SEOSocialPreviewDebugPlatform, urlText: String) {
    self.platform = platform
    self.urlText = urlText
  }

  public var title: String {
    platform.displayName
  }

  public var purpose: String {
    platform.purpose
  }

  public var systemImage: String {
    platform.systemImage
  }

  public var clipboardLine: String {
    "\(title)：\(urlText)"
  }
}

public enum SEOSocialPreviewRenderingMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case staticMetadataSnapshot

  public var id: String { rawValue }

  public var displayName: String {
    "静态元数据快照"
  }

  public var message: String {
    "当前预览由草稿、Front Matter 和封面元数据生成；外部调试链接用于发布后确认真实平台抓取效果。"
  }
}

public struct SEOStructuredDataPreview: Identifiable, Codable, Hashable, Sendable {
  public var id: String { "json-ld" }
  public var status: SEOSocialPreviewReadinessStatus
  public var title: String
  public var message: String
  public var jsonLD: String
  public var missingRequiredFields: [String]
  public var warningMessages: [String]

  public init(
    status: SEOSocialPreviewReadinessStatus,
    title: String,
    message: String,
    jsonLD: String,
    missingRequiredFields: [String] = [],
    warningMessages: [String] = []
  ) {
    self.status = status
    self.title = title
    self.message = message
    self.jsonLD = jsonLD
    self.missingRequiredFields = missingRequiredFields
    self.warningMessages = warningMessages
  }
}

public struct SEOSitemapEntry: Identifiable, Codable, Hashable, Sendable {
  public var id: String { loc }
  public var loc: String
  public var lastmod: String
  public var title: String
  public var isSelectedDraft: Bool

  public init(
    loc: String,
    lastmod: String,
    title: String,
    isSelectedDraft: Bool = false
  ) {
    self.loc = loc
    self.lastmod = lastmod
    self.title = title
    self.isSelectedDraft = isSelectedDraft
  }
}

public struct SEOSitemapPreview: Identifiable, Codable, Hashable, Sendable {
  public var id: String { "sitemap" }
  public var status: SEOSocialPreviewReadinessStatus
  public var title: String
  public var message: String
  public var sitemapURLText: String?
  public var entries: [SEOSitemapEntry]
  public var xml: String

  public init(
    status: SEOSocialPreviewReadinessStatus,
    title: String,
    message: String,
    sitemapURLText: String?,
    entries: [SEOSitemapEntry],
    xml: String
  ) {
    self.status = status
    self.title = title
    self.message = message
    self.sitemapURLText = sitemapURLText
    self.entries = entries
    self.xml = xml
  }
}

public struct SEOSocialPreviewSnapshot: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var signature: String
  public var renderingMode: SEOSocialPreviewRenderingMode
  public var markdownPath: String
  public var canonicalURLText: String
  public var titleCharacterCount: Int
  public var descriptionCharacterCount: Int
  public var imagePath: String?
  public var socialImageURLText: String?
  public var imageDimensions: ImageDimensions?
  public var imageAltText: String?
  public var shareHashtags: [String]
  public var cards: [SEOSocialPreviewCard]
  public var metaTags: [SEOSocialPreviewMetaTag]
  public var structuredData: SEOStructuredDataPreview
  public var findings: [SEOAuditFinding]
  public var generatedAt: Date

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    signature: String,
    renderingMode: SEOSocialPreviewRenderingMode = .staticMetadataSnapshot,
    markdownPath: String,
    canonicalURLText: String,
    titleCharacterCount: Int,
    descriptionCharacterCount: Int,
    imagePath: String?,
    socialImageURLText: String? = nil,
    imageDimensions: ImageDimensions? = nil,
    imageAltText: String? = nil,
    shareHashtags: [String] = [],
    cards: [SEOSocialPreviewCard],
    metaTags: [SEOSocialPreviewMetaTag] = [],
    structuredData: SEOStructuredDataPreview = SEOStructuredDataPreview(
      status: .warning,
      title: "结构化数据未生成",
      message: "刷新快照后生成 JSON-LD。",
      jsonLD: "{}",
      warningMessages: ["旧缓存缺少 JSON-LD 预览。"]
    ),
    findings: [SEOAuditFinding],
    generatedAt: Date = Date()
  ) {
    self.id = id
    self.draftID = draftID
    self.signature = signature
    self.renderingMode = renderingMode
    self.markdownPath = markdownPath
    self.canonicalURLText = canonicalURLText
    self.titleCharacterCount = titleCharacterCount
    self.descriptionCharacterCount = descriptionCharacterCount
    self.imagePath = imagePath
    self.socialImageURLText = socialImageURLText
    self.imageDimensions = imageDimensions
    self.imageAltText = imageAltText
    self.shareHashtags = shareHashtags
    self.cards = cards
    self.metaTags = metaTags
    self.structuredData = structuredData
    self.findings = findings
    self.generatedAt = generatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case draftID
    case signature
    case renderingMode
    case markdownPath
    case canonicalURLText
    case titleCharacterCount
    case descriptionCharacterCount
    case imagePath
    case socialImageURLText
    case imageDimensions
    case imageAltText
    case shareHashtags
    case cards
    case metaTags
    case structuredData
    case findings
    case generatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    draftID = try container.decode(UUID.self, forKey: .draftID)
    signature = try container.decode(String.self, forKey: .signature)
    renderingMode = try container.decodeIfPresent(
      SEOSocialPreviewRenderingMode.self,
      forKey: .renderingMode
    ) ?? .staticMetadataSnapshot
    markdownPath = try container.decode(String.self, forKey: .markdownPath)
    canonicalURLText = try container.decode(String.self, forKey: .canonicalURLText)
    titleCharacterCount = try container.decode(Int.self, forKey: .titleCharacterCount)
    descriptionCharacterCount = try container.decode(Int.self, forKey: .descriptionCharacterCount)
    imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
    socialImageURLText = try container.decodeIfPresent(String.self, forKey: .socialImageURLText)
    imageDimensions = try container.decodeIfPresent(ImageDimensions.self, forKey: .imageDimensions)
    imageAltText = try container.decodeIfPresent(String.self, forKey: .imageAltText)
    shareHashtags = try container.decodeIfPresent([String].self, forKey: .shareHashtags) ?? []
    cards = try container.decode([SEOSocialPreviewCard].self, forKey: .cards)
    metaTags = try container.decodeIfPresent([SEOSocialPreviewMetaTag].self, forKey: .metaTags) ?? []
    structuredData = try container.decodeIfPresent(
      SEOStructuredDataPreview.self,
      forKey: .structuredData
    ) ?? SEOStructuredDataPreview(
      status: .warning,
      title: "结构化数据未生成",
      message: "旧缓存缺少 JSON-LD 预览，请手动刷新。",
      jsonLD: "{}",
      warningMessages: ["旧缓存缺少 JSON-LD 预览。"]
    )
    findings = try container.decode([SEOAuditFinding].self, forKey: .findings)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
  }
}

public enum SEOSocialPreviewCacheState: String, Codable, CaseIterable, Identifiable, Sendable {
  case missing
  case fresh
  case stale

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .missing:
      return "未生成快照"
    case .fresh:
      return "缓存可用"
    case .stale:
      return "缓存已过期"
    }
  }

  public var systemImage: String {
    switch self {
    case .missing:
      return "rectangle.on.rectangle.slash"
    case .fresh:
      return "checkmark.circle"
    case .stale:
      return "clock.badge.exclamationmark"
    }
  }
}

public struct SEOSocialPreviewCachePresentation: Codable, Hashable, Sendable {
  public var state: SEOSocialPreviewCacheState
  public var generatedAt: Date?
  public var message: String
  public var manualRefreshTitle: String

  public init(
    snapshot: SEOSocialPreviewSnapshot?,
    isStale: Bool
  ) {
    if let snapshot {
      state = isStale ? .stale : .fresh
      generatedAt = snapshot.generatedAt
    } else {
      state = .missing
      generatedAt = nil
    }

    switch state {
    case .missing:
      message = "点击手动刷新生成搜索、Open Graph 和 Twitter/X 预览快照。"
      manualRefreshTitle = "生成快照"
    case .fresh:
      message = "正在使用缓存快照；只有明确刷新才会重新生成社交预览。"
      manualRefreshTitle = "手动刷新"
    case .stale:
      message = "当前显示的是上次缓存快照；复制发布包前请手动刷新。"
      manualRefreshTitle = "刷新过期快照"
    }
  }

  public var hasSnapshot: Bool {
    state != .missing
  }

  public var needsManualRefresh: Bool {
    state != .fresh
  }
}

public extension SEOSocialPreviewSnapshot {
  var socialShareCopyItems: [SEOSocialShareCopyItem] {
    cards.map { card in
      SEOSocialShareCopyItem(
        kind: card.kind,
        title: shareTitle(for: card),
        body: card.description,
        urlText: card.urlText,
        imagePath: card.imagePath,
        imageURLText: card.kind == .search ? nil : socialImageURLText,
        hashtags: shareHashtags
      )
    }
  }

  var externalDebugLinks: [SEOSocialPreviewDebugLink] {
    guard let canonicalURL = canonicalURLText.trimmedForPublishing.nilIfEmpty else {
      return []
    }
    let title = cards.first(where: { $0.kind == .twitter })?.title.nilIfEmpty
      ?? cards.first?.title.nilIfEmpty
      ?? ""

    return SEOSocialPreviewDebugPlatform.allCases.compactMap { platform in
      guard let urlText = debugURLText(for: platform, canonicalURLText: canonicalURL, title: title) else {
        return nil
      }
      return SEOSocialPreviewDebugLink(platform: platform, urlText: urlText)
    }
  }

  var platformReadiness: [SEOSocialPreviewPlatformReadiness] {
    SEOSocialPreviewCardKind.allCases.compactMap { kind in
      guard let card = cards.first(where: { $0.kind == kind }) else {
        return SEOSocialPreviewPlatformReadiness(
          kind: kind,
          status: .missing,
          title: "\(kind.displayName) 缺少预览",
          message: "没有生成 \(kind.displayName) 卡片。",
          missingRequiredProperties: ["previewCard"]
        )
      }

      let scopedTags = metaTags.filter { $0.scope == kind }
      let tagContentByProperty = Dictionary(
        scopedTags.map { ($0.property, $0.content) },
        uniquingKeysWith: { first, _ in first }
      )
      let missingRequired = requiredMetaProperties(for: kind).filter {
        tagContentByProperty[$0]?.trimmedForPublishing.nilIfEmpty == nil
      }
      var warnings: [String] = []
      if !card.isTitleWithinBudget {
        warnings.append("标题 \(card.titleBudgetText)，可能在 \(kind.displayName) 中截断。")
      }
      if !card.isDescriptionWithinBudget {
        warnings.append("描述 \(card.descriptionBudgetText)，可能在 \(kind.displayName) 中截断。")
      }
      if kind != .search && card.imagePath == nil {
        warnings.append("\(kind.displayName) 缺少大图，分享时会降级为纯文本或小卡片。")
      }
      if kind != .search,
         card.imagePath != nil,
         card.imageAltText?.trimmedForPublishing.nilIfEmpty == nil {
        warnings.append("\(kind.displayName) 社交图缺少 Alt 文本，建议补齐 og:image:alt / twitter:image:alt。")
      }
      if kind != .search, let dimensions = card.imageDimensions {
        warnings.append(contentsOf: socialImageWarnings(for: kind, dimensions: dimensions))
      }

      let status: SEOSocialPreviewReadinessStatus
      if !missingRequired.isEmpty {
        status = .missing
      } else if !warnings.isEmpty {
        status = .warning
      } else {
        status = .ready
      }

      return SEOSocialPreviewPlatformReadiness(
        kind: kind,
        status: status,
        title: readinessTitle(kind: kind, status: status),
        message: readinessMessage(status: status, missingRequired: missingRequired, warnings: warnings),
        missingRequiredProperties: missingRequired,
        warningMessages: warnings,
        copyableMetaTags: scopedTags
      )
    }
  }

  var socialShareChecklistMarkdown: String {
    var lines = [
      "# SEO / Social Preview Checklist",
      "",
      "- Rendering: \(renderingMode.displayName)",
      "- URL: \(canonicalURLText)",
      "- Markdown: \(markdownPath)",
      "- Title: \(titleCharacterCount) chars",
      "- Description: \(descriptionCharacterCount) chars",
      "- Image: \(imagePath ?? "none")",
      "- Image URL: \(socialImageURLText ?? "none")",
      "- Image size: \(imageDimensions?.displayName ?? "unknown")",
      "- Image alt: \(imageAltText?.nilIfEmpty ?? "missing")",
      "- Hashtags: \(shareHashtags.isEmpty ? "none" : shareHashtags.map { "#\($0)" }.joined(separator: " "))",
      "",
      "## Platform Readiness",
    ]
    for item in platformReadiness {
      lines.append("- \(item.kind.displayName): \(item.status.displayName) - \(item.message)")
      for missing in item.missingRequiredProperties {
        lines.append("  - Missing: \(missing)")
      }
      for warning in item.warningMessages {
        lines.append("  - Warning: \(warning)")
      }
    }
    lines.append("")
    lines.append("## Structured Data")
    lines.append("- JSON-LD: \(structuredData.status.displayName) - \(structuredData.message)")
    for missing in structuredData.missingRequiredFields {
      lines.append("  - Missing: \(missing)")
    }
    for warning in structuredData.warningMessages {
      lines.append("  - Warning: \(warning)")
    }
    let debugLinks = externalDebugLinks
    if !debugLinks.isEmpty {
      lines.append("")
      lines.append("## External Debug Links")
      for link in debugLinks {
        lines.append("- [ ] \(link.title): \(link.urlText)")
        lines.append("  - Purpose: \(link.purpose)")
      }
    }
    if !findings.isEmpty {
      lines.append("")
      lines.append("## Findings")
      for finding in findings {
        lines.append("- [\(finding.severity.displayName)] \(finding.title): \(finding.message)")
      }
    }
    return lines.joined(separator: "\n")
  }

  func publishPackageMarkdown(
    relatedSuggestions: [SiteRelationSuggestion] = []
  ) -> String {
    var lines = [
      "# SEO / Social 发布包",
      "",
      "- 预览类型：\(renderingMode.displayName)",
      "- 预览说明：\(renderingMode.message)",
      "- URL：\(canonicalURLText)",
      "- Markdown：\(markdownPath)",
      "- 标题字数：\(titleCharacterCount)",
      "- 描述字数：\(descriptionCharacterCount)",
      "- 图片：\(imagePath ?? "none")",
      "- 图片 URL：\(socialImageURLText ?? "none")",
      "- 图片尺寸：\(imageDimensions?.displayName ?? "unknown")",
      "- 图片 Alt：\(imageAltText?.nilIfEmpty ?? "missing")",
      "- 快照时间：\(ISO8601DateFormatter().string(from: generatedAt))",
      "",
      "## 平台就绪度",
    ]

    for item in platformReadiness {
      lines.append("- \(item.kind.displayName)：\(item.status.displayName) - \(item.message)")
      for missing in item.missingRequiredProperties {
        lines.append("  - 缺少：\(missing)")
      }
      for warning in item.warningMessages {
        lines.append("  - 警告：\(warning)")
      }
    }

    lines.append("")
    lines.append("## 结构化数据")
    lines.append("- 状态：\(structuredData.status.displayName)")
    lines.append("- 说明：\(structuredData.message)")
    if !structuredData.missingRequiredFields.isEmpty {
      lines.append("- 缺少字段：\(structuredData.missingRequiredFields.joined(separator: "、"))")
    }
    if !structuredData.warningMessages.isEmpty {
      lines.append("- 建议确认：\(structuredData.warningMessages.joined(separator: "；"))")
    }
    lines.append("```json")
    lines.append(structuredData.jsonLD)
    lines.append("```")

    lines.append("")
    lines.append("## 分享文案")
    for item in socialShareCopyItems {
      lines.append("- \(item.kind.displayName)")
      lines.append("  - 标题：\(item.title)")
      lines.append("  - 正文：\(item.body)")
      lines.append("  - 链接：\(item.urlText)")
      if let imagePath = item.imagePath?.nilIfEmpty {
        lines.append("  - 图片：\(imagePath)")
      }
      if let imageURLText = item.imageURLText?.nilIfEmpty {
        lines.append("  - 图片 URL：\(imageURLText)")
      }
      if !item.hashtags.isEmpty {
        lines.append("  - Hashtags：\(item.hashtagText)")
      }
    }

    lines.append("")
    lines.append("## 卡片预览")
    for card in cards {
      lines.append("- \(card.kind.displayName)：\(card.title)")
      lines.append("  - 描述：\(card.description)")
      lines.append("  - URL：\(card.urlText)")
      if let imagePath = card.imagePath?.nilIfEmpty {
        lines.append("  - 图片：\(imagePath)")
      }
      if card.kind != .search,
         let socialImageURLText = socialImageURLText?.nilIfEmpty {
        lines.append("  - 图片 URL：\(socialImageURLText)")
      }
      if let imageDimensions = card.imageDimensions {
        lines.append("  - 图片尺寸：\(imageDimensions.displayName)")
      }
      if let imageAltText = card.imageAltText?.nilIfEmpty {
        lines.append("  - 图片 Alt：\(imageAltText)")
      }
    }

    if !relatedSuggestions.isEmpty {
      lines.append("")
      lines.append("## 关联文章建议")
      for suggestion in relatedSuggestions {
        lines.append("- \(suggestion.sourceTitle) -> \(suggestion.targetTitle)")
        lines.append("  - 路径：\(suggestion.targetPath)")
        lines.append("  - 原因：\(suggestion.reason)")
        if !suggestion.sharedLabels.isEmpty {
          lines.append("  - 共同标签：\(suggestion.sharedLabels.joined(separator: "、"))")
        }
      }
    }

    let debugLinks = externalDebugLinks
    if !debugLinks.isEmpty {
      lines.append("")
      lines.append("## 外部调试链接")
      for link in debugLinks {
        lines.append("- \(link.title)：\(link.urlText)")
        lines.append("  - 用途：\(link.purpose)")
      }
    }

    if !metaTags.isEmpty {
      lines.append("")
      lines.append("## Meta HTML")
      lines.append("```html")
      lines.append(metaTags.htmlBlock)
      lines.append("```")
    }

    if !findings.isEmpty {
      lines.append("")
      lines.append("## 检查发现")
      for finding in findings {
        lines.append("- [\(finding.severity.displayName)] \(finding.title)：\(finding.message)")
      }
    }

    return lines.joined(separator: "\n")
  }

  private func debugURLText(
    for platform: SEOSocialPreviewDebugPlatform,
    canonicalURLText: String,
    title: String
  ) -> String? {
    switch platform {
    case .facebookSharingDebugger:
      var components = URLComponents(string: "https://developers.facebook.com/tools/debug/")
      components?.queryItems = [URLQueryItem(name: "q", value: canonicalURLText)]
      return components?.url?.absoluteString
    case .linkedinPostInspector:
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
      let encodedURL = canonicalURLText.addingPercentEncoding(withAllowedCharacters: allowed) ?? canonicalURLText
      return "https://www.linkedin.com/post-inspector/inspect/\(encodedURL)"
    case .xShareIntent:
      var components = URLComponents(string: "https://twitter.com/intent/tweet")
      components?.queryItems = [
        URLQueryItem(name: "url", value: canonicalURLText),
        URLQueryItem(name: "text", value: title),
      ]
      return components?.url?.absoluteString
    case .xCardValidator:
      return "https://cards-dev.twitter.com/validator"
    }
  }

  private func shareTitle(for card: SEOSocialPreviewCard) -> String {
    switch card.kind {
    case .search:
      return "\(card.title) - 搜索摘要"
    case .openGraph:
      return "\(card.title) - 链接分享"
    case .twitter:
      return card.title
    }
  }

  private func requiredMetaProperties(for kind: SEOSocialPreviewCardKind) -> [String] {
    switch kind {
    case .search:
      return ["description"]
    case .openGraph:
      return ["og:type", "og:site_name", "og:title", "og:description", "og:url"]
    case .twitter:
      return ["twitter:card", "twitter:title", "twitter:description"]
    }
  }

  private func readinessTitle(
    kind: SEOSocialPreviewCardKind,
    status: SEOSocialPreviewReadinessStatus
  ) -> String {
    switch status {
    case .ready:
      return "\(kind.displayName) 可发布"
    case .warning:
      return "\(kind.displayName) 需确认"
    case .missing:
      return "\(kind.displayName) 缺少字段"
    }
  }

  private func readinessMessage(
    status: SEOSocialPreviewReadinessStatus,
    missingRequired: [String],
    warnings: [String]
  ) -> String {
    switch status {
    case .ready:
      return "必填字段齐全，标题和描述在建议范围内。"
    case .warning:
      return warnings.first ?? "字段齐全，但建议发布前复核。"
    case .missing:
      return "缺少 \(missingRequired.joined(separator: ", "))。"
    }
  }

  private func socialImageWarnings(
    for kind: SEOSocialPreviewCardKind,
    dimensions: ImageDimensions
  ) -> [String] {
    guard kind != .search else {
      return []
    }

    let minimumHeight = kind == .twitter ? 628 : 630
    var warnings: [String] = []
    if dimensions.width < 1200 || dimensions.height < minimumHeight {
      warnings.append("\(kind.displayName) 图片尺寸 \(dimensions.displayName)，建议至少 1200x\(minimumHeight)。")
    }

    let actualRatio = Double(dimensions.width) / Double(max(dimensions.height, 1))
    let targetRatio = 1200.0 / Double(minimumHeight)
    if abs(actualRatio - targetRatio) > 0.08 {
      warnings.append("\(kind.displayName) 图片比例 \(String(format: "%.2f", actualRatio)):1，建议接近 1.91:1。")
    }
    return warnings
  }
}
