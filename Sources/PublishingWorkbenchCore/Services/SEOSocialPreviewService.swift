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

public struct SEOSocialPreviewService {
  public init() {}

  public func snapshot(
    draft: ArticleDraft,
    profile: SiteProfile,
    localPreviewURL: URL? = nil
  ) -> SEOSocialPreviewSnapshot {
    let title = socialTitle(for: draft)
    let description = socialDescription(for: draft)
    let markdownPath = profile.markdownPath(for: draft)
    let canonicalURLText = canonicalURL(
      markdownPath: markdownPath,
      profile: profile,
      localPreviewURL: localPreviewURL
    )
    let cover = coverAttachment(for: draft)
    let imagePath = draft.isPrivate ? nil : cover?.relativePublishPath.nilIfEmpty
    let imageAltText = draft.isPrivate ? nil : cover?.altText.nilIfEmpty
    let imageDimensions = draft.isPrivate ? nil : cover.flatMap(imageDimensions(for:))
    let imageURLText = socialImageURL(imagePath: imagePath, canonicalURLText: canonicalURLText)

    let cards = SEOSocialPreviewCardKind.allCases.map { kind in
      let specification = cardSpecification(for: kind)
      return SEOSocialPreviewCard(
        kind: kind,
        title: title,
        description: description,
        urlText: kind == .search ? displayURL(canonicalURLText) : canonicalURLText,
        imagePath: kind == .search ? nil : imagePath,
        imageAltText: kind == .search ? nil : imageAltText,
        imageDimensions: kind == .search ? nil : imageDimensions,
        siteName: profile.name,
        titleCharacterLimit: specification.titleCharacterLimit,
        descriptionCharacterLimit: specification.descriptionCharacterLimit,
        imageAspectRatio: specification.imageAspectRatio,
        imageGuidance: specification.imageGuidance
      )
    }
    let metaTags = socialMetaTags(
      title: title,
      description: description,
      canonicalURLText: canonicalURLText,
      imageURLText: imageURLText,
      imageAltText: imageAltText,
      imageDimensions: imageDimensions,
      siteName: profile.name,
      publishedAt: draft.date,
      modifiedAt: draft.updatedAt,
      authors: articleAuthors(for: draft, profile: profile),
      sections: socialLabels(from: draft.categories),
      articleTags: socialLabels(from: draft.tags)
    )
    let structuredData = structuredDataPreview(
      title: title,
      description: description,
      canonicalURLText: canonicalURLText,
      imageURLText: imageURLText,
      siteName: profile.name,
      publishedAt: draft.date,
      modifiedAt: draft.updatedAt,
      authors: articleAuthors(for: draft, profile: profile),
      articleTags: socialLabels(from: draft.tags)
    )

    return SEOSocialPreviewSnapshot(
      draftID: draft.id,
      signature: signature(draft: draft, profile: profile, localPreviewURL: localPreviewURL),
      renderingMode: .staticMetadataSnapshot,
      markdownPath: markdownPath,
      canonicalURLText: canonicalURLText,
      titleCharacterCount: title.count,
      descriptionCharacterCount: description.count,
      imagePath: imagePath,
      socialImageURLText: imageURLText,
      imageDimensions: imageDimensions,
      imageAltText: imageAltText,
      shareHashtags: shareHashtags(for: draft),
      cards: cards,
      metaTags: metaTags,
      structuredData: structuredData,
      findings: findings(
        title: title,
        description: description,
        imagePath: imagePath,
        imageAltText: imageAltText,
        draft: draft,
        structuredData: structuredData
      ),
      generatedAt: Date()
    )
  }

  public func sitemapPreview(
    drafts: [ArticleDraft],
    selectedDraft: ArticleDraft,
    profile: SiteProfile,
    localPreviewURL: URL? = nil
  ) -> SEOSitemapPreview {
    let sitemapURLText = sitemapURL(profile: profile, localPreviewURL: localPreviewURL)
    let eligibleDrafts = drafts
      .filter { $0.belongs(toSiteProfileID: profile.id) && !$0.isPrivate && !$0.draft }
      .sorted {
        if $0.date == $1.date {
          return $0.title < $1.title
        }
        return $0.date > $1.date
      }
    let entries = eligibleDrafts.map { draft in
      SEOSitemapEntry(
        loc: canonicalURL(
          markdownPath: profile.markdownPath(for: draft),
          profile: profile,
          localPreviewURL: localPreviewURL
        ),
        lastmod: iso8601DateString(from: draft.updatedAt),
        title: draft.title.trimmedForPublishing.nilIfEmpty ?? draft.slug,
        isSelectedDraft: draft.id == selectedDraft.id
      )
    }
    let selectedEntry = entries.first { $0.isSelectedDraft }
    let xml = sitemapXML(entries: entries)

    if sitemapURLText == nil {
      return SEOSitemapPreview(
        status: .missing,
        title: "缺少 sitemap 站点地址",
        message: "请配置部署站点 URL，或启动本地预览后再生成可提交的 sitemap.xml。",
        sitemapURLText: nil,
        entries: entries,
        xml: xml
      )
    }

    if selectedDraft.isPrivate || selectedDraft.draft {
      return SEOSitemapPreview(
        status: .warning,
        title: "当前文章不会进入 sitemap",
        message: "私密文章或草稿不应出现在 sitemap.xml 中。",
        sitemapURLText: sitemapURLText,
        entries: entries,
        xml: xml
      )
    }

    if selectedEntry == nil {
      return SEOSitemapPreview(
        status: .warning,
        title: "当前文章未进入 sitemap",
        message: "当前文章没有出现在生成的 sitemap 条目中，请检查站点资料和文章归属。",
        sitemapURLText: sitemapURLText,
        entries: entries,
        xml: xml
      )
    }

    return SEOSitemapPreview(
      status: .ready,
      title: "sitemap.xml 可生成",
      message: "当前公开文章已包含在 sitemap.xml 预览中。",
      sitemapURLText: sitemapURLText,
      entries: entries,
      xml: xml
    )
  }

  public func signature(
    draft: ArticleDraft,
    profile: SiteProfile,
    localPreviewURL: URL? = nil
  ) -> String {
    let cover = coverAttachment(for: draft)
    let dimensions = cover.flatMap(imageDimensions(for:))
    let parts: [String] = [
      draft.title,
      draft.summary,
      draft.slug,
      String(draft.date.timeIntervalSince1970),
      draft.visibility.rawValue,
      draft.coverAttachmentID?.uuidString ?? "",
      cover?.relativePublishPath ?? "",
      cover?.altText ?? "",
      cover?.sourceFilePath ?? "",
      String(cover?.byteSize ?? 0),
      cover.flatMap(sourceFileModifiedTimestamp(for:)).map { String($0) } ?? "",
      dimensions?.displayName ?? "",
      draft.tags.joined(separator: ","),
      draft.categories.joined(separator: ","),
      draft.authors.joined(separator: ","),
      String(draft.updatedAt.timeIntervalSince1970),
      profile.name,
      profile.deploymentSiteURL ?? "",
      profile.defaultAuthor,
      profile.markdownPath(for: draft),
      localPreviewURL?.absoluteString ?? "",
    ]
    return parts.joined(separator: "\u{1F}")
  }

  private func socialTitle(for draft: ArticleDraft) -> String {
    draft.title.trimmedForPublishing.nilIfEmpty ?? "未命名文章"
  }

  private func socialDescription(for draft: ArticleDraft) -> String {
    if let summary = draft.summary.nilIfEmpty {
      return summary
    }

    return plainTextExcerpt(from: draft.bodyMarkdown).nilIfEmpty ?? "暂无摘要。"
  }

  private func canonicalURL(
    markdownPath: String,
    profile: SiteProfile,
    localPreviewURL: URL?
  ) -> String {
    let resolver = SiteArticleURLResolver()
    let relativeURLPath = resolver.relativeWebPath(from: markdownPath, siteKind: profile.siteKind)
    let profileDeploymentURL = profile.deploymentSiteURL
      .flatMap { URL(string: $0.trimmedForPublishing) }
      .flatMap { url in
        url.scheme != nil && url.host != nil ? url : nil
      }
    if let baseURL = localPreviewURL ?? profileDeploymentURL {
      return resolver.url(baseURL: baseURL, markdownPath: markdownPath, siteKind: profile.siteKind)?.absoluteString ?? relativeURLPath
    }

    return relativeURLPath
  }

  private func displayURL(_ urlText: String) -> String {
    urlText
      .replacingOccurrences(of: "https://", with: "")
      .replacingOccurrences(of: "http://", with: "")
  }

  private func socialImageURL(imagePath: String?, canonicalURLText: String) -> String? {
    guard let imagePath else {
      return nil
    }
    guard imagePath.hasPrefix("/"),
          let canonicalURL = URL(string: canonicalURLText),
          let scheme = canonicalURL.scheme,
          let host = canonicalURL.host else {
      return imagePath
    }

    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = canonicalURL.port
    components.path = imagePath
    return components.url?.absoluteString ?? imagePath
  }

  private func socialMetaTags(
    title: String,
    description: String,
    canonicalURLText: String,
    imageURLText: String?,
    imageAltText: String?,
    imageDimensions: ImageDimensions?,
    siteName: String,
    publishedAt: Date,
    modifiedAt: Date,
    authors: [String],
    sections: [String],
    articleTags: [String]
  ) -> [SEOSocialPreviewMetaTag] {
    var tags: [SEOSocialPreviewMetaTag] = [
      SEOSocialPreviewMetaTag(scope: .search, property: "description", content: description),
      SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:type", content: "article"),
      SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:site_name", content: siteName),
      SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:title", content: title),
      SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:description", content: description),
      SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:url", content: canonicalURLText),
      SEOSocialPreviewMetaTag(
        scope: .twitter,
        property: "twitter:card",
        content: imageURLText == nil ? "summary" : "summary_large_image"
      ),
      SEOSocialPreviewMetaTag(scope: .twitter, property: "twitter:title", content: title),
      SEOSocialPreviewMetaTag(scope: .twitter, property: "twitter:description", content: description),
    ]

    tags.append(SEOSocialPreviewMetaTag(scope: .openGraph, property: "article:published_time", content: iso8601String(from: publishedAt), isRequired: false))
    tags.append(SEOSocialPreviewMetaTag(scope: .openGraph, property: "article:modified_time", content: iso8601String(from: modifiedAt), isRequired: false))
    for author in authors {
      tags.append(SEOSocialPreviewMetaTag(scope: .openGraph, property: "article:author", content: author, isRequired: false))
    }
    for section in sections {
      tags.append(SEOSocialPreviewMetaTag(scope: .openGraph, property: "article:section", content: section, isRequired: false))
    }
    for tag in articleTags {
      tags.append(SEOSocialPreviewMetaTag(scope: .openGraph, property: "article:tag", content: tag, isRequired: false))
    }

    if let imageURLText {
      tags.append(SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:image", content: imageURLText))
      tags.append(
        SEOSocialPreviewMetaTag(
          scope: .openGraph,
          property: "og:image:width",
          content: String(imageDimensions?.width ?? 1200),
          isRequired: false
        )
      )
      tags.append(
        SEOSocialPreviewMetaTag(
          scope: .openGraph,
          property: "og:image:height",
          content: String(imageDimensions?.height ?? 630),
          isRequired: false
        )
      )
      tags.append(SEOSocialPreviewMetaTag(scope: .twitter, property: "twitter:image", content: imageURLText))
    }
    if let imageAltText {
      tags.append(SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:image:alt", content: imageAltText, isRequired: false))
      tags.append(SEOSocialPreviewMetaTag(scope: .twitter, property: "twitter:image:alt", content: imageAltText, isRequired: false))
    }

    return tags
  }

  private func iso8601String(from date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private func iso8601DateString(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private func structuredDataPreview(
    title: String,
    description: String,
    canonicalURLText: String,
    imageURLText: String?,
    siteName: String,
    publishedAt: Date,
    modifiedAt: Date,
    authors: [String],
    articleTags: [String]
  ) -> SEOStructuredDataPreview {
    var missing: [String] = []
    var warnings: [String] = []
    if title.trimmedForPublishing.isEmpty {
      missing.append("headline")
    }
    if description.trimmedForPublishing.isEmpty {
      missing.append("description")
    }
    if canonicalURLText.trimmedForPublishing.isEmpty {
      missing.append("url")
    } else if URL(string: canonicalURLText)?.scheme == nil {
      warnings.append("JSON-LD url 当前是相对路径，发布前建议使用部署站点绝对 URL。")
    }
    if imageURLText == nil {
      warnings.append("缺少 image，Article JSON-LD 在搜索结果中可能失去富媒体展示机会。")
    }
    if authors.isEmpty {
      warnings.append("缺少 author，建议配置文章作者或站点默认作者。")
    }

    var object: [String: Any] = [
      "@context": "https://schema.org",
      "@type": "Article",
      "headline": title,
      "description": description,
      "url": canonicalURLText,
      "mainEntityOfPage": [
        "@type": "WebPage",
        "@id": canonicalURLText,
      ],
      "datePublished": iso8601String(from: publishedAt),
      "dateModified": iso8601String(from: modifiedAt),
      "publisher": [
        "@type": "Organization",
        "name": siteName.trimmedForPublishing.nilIfEmpty ?? "个人网站",
      ],
    ]
    if let imageURLText {
      object["image"] = [imageURLText]
    }
    if !authors.isEmpty {
      object["author"] = authors.map { ["@type": "Person", "name": $0] }
    }
    if !articleTags.isEmpty {
      object["keywords"] = articleTags.joined(separator: ", ")
    }

    let jsonLD = prettyJSONString(object)
    if !missing.isEmpty {
      return SEOStructuredDataPreview(
        status: .missing,
        title: "JSON-LD 缺少必填字段",
        message: "缺少 \(missing.joined(separator: ", "))。",
        jsonLD: jsonLD,
        missingRequiredFields: missing,
        warningMessages: warnings
      )
    }
    if !warnings.isEmpty {
      return SEOStructuredDataPreview(
        status: .warning,
        title: "JSON-LD 需确认",
        message: warnings.first ?? "结构化数据已生成，发布前建议复核。",
        jsonLD: jsonLD,
        warningMessages: warnings
      )
    }
    return SEOStructuredDataPreview(
      status: .ready,
      title: "JSON-LD 可发布",
      message: "Article 结构化数据字段完整，可复制到主题模板或发布包。",
      jsonLD: jsonLD
    )
  }

  private func prettyJSONString(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          ),
          let text = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return text
  }

  private func sitemapURL(profile: SiteProfile, localPreviewURL: URL?) -> String? {
    let profileDeploymentURL = profile.deploymentSiteURL
      .flatMap { URL(string: $0.trimmedForPublishing) }
      .flatMap { url in
        url.scheme != nil && url.host != nil ? url : nil
      }
    guard let url = localPreviewURL ?? profileDeploymentURL,
          let scheme = url.scheme,
          let host = url.host else {
      return nil
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    let basePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = "/" + ([basePath, "sitemap.xml"].filter { !$0.isEmpty }.joined(separator: "/"))
    return components.url?.absoluteString
  }

  private func sitemapXML(entries: [SEOSitemapEntry]) -> String {
    var lines = [
      #"<?xml version="1.0" encoding="UTF-8"?>"#,
      #"<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">"#,
    ]
    for entry in entries {
      lines.append("  <url>")
      lines.append("    <loc>\(xmlEscaped(entry.loc))</loc>")
      lines.append("    <lastmod>\(xmlEscaped(entry.lastmod))</lastmod>")
      lines.append("  </url>")
    }
    lines.append("</urlset>")
    return lines.joined(separator: "\n")
  }

  private func xmlEscaped(_ value: String) -> String {
    MarkupEscaping.xmlText(value)
  }

  private func cardSpecification(
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

  private func shareHashtags(for draft: ArticleDraft) -> [String] {
    var seen = Set<String>()
    return (draft.tags + draft.categories)
      .compactMap { rawValue in
        guard let value = socialShareHashtag(from: rawValue) else {
          return nil
        }
        let key = value.lowercased()
        guard !seen.contains(key) else {
          return nil
        }
        seen.insert(key)
        return value
      }
      .prefix(5)
      .map { $0 }
  }

  private func socialShareHashtag(from rawValue: String) -> String? {
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"^[#]+"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"[^A-Za-z0-9_\-\p{Han}]"#, with: "", options: .regularExpression)
    return normalized.nilIfEmpty
  }

  private func socialLabels(from rawValues: [String]) -> [String] {
    var seen = Set<String>()
    return rawValues.compactMap { rawValue in
      let normalized = rawValue
        .trimmedForPublishing
        .replacingOccurrences(of: #"^[#]+"#, with: "", options: .regularExpression)
      guard let value = normalized.nilIfEmpty else {
        return nil
      }
      let key = value.lowercased()
      guard !seen.contains(key) else {
        return nil
      }
      seen.insert(key)
      return value
    }
  }

  private func articleAuthors(for draft: ArticleDraft, profile: SiteProfile) -> [String] {
    let authors = socialLabels(from: draft.authors)
    if !authors.isEmpty {
      return authors
    }
    return socialLabels(from: [profile.defaultAuthor])
  }

  private func coverAttachment(for draft: ArticleDraft) -> DraftAttachment? {
    guard let coverAttachmentID = draft.coverAttachmentID else {
      return nil
    }
    return draft.attachments.first { $0.id == coverAttachmentID }
  }

  private func imageDimensions(for attachment: DraftAttachment) -> ImageDimensions? {
    guard let sourceFilePath = attachment.sourceFilePath?.nilIfEmpty else {
      return nil
    }
    let url = URL(fileURLWithPath: sourceFilePath)
    guard FileManager.default.fileExists(atPath: url.path),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
      return nil
    }
    return ImageDimensions(width: width.intValue, height: height.intValue)
  }

  private func sourceFileModifiedTimestamp(for attachment: DraftAttachment) -> TimeInterval? {
    guard let sourceFilePath = attachment.sourceFilePath?.nilIfEmpty else {
      return nil
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: sourceFilePath)
    return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
  }

  private func plainTextExcerpt(from markdown: String) -> String {
    markdown
      .components(separatedBy: .newlines)
      .map { line in
        line
          .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]+\)"#, with: "", options: .regularExpression)
          .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
          .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func findings(
    title: String,
    description: String,
    imagePath: String?,
    imageAltText: String?,
    draft: ArticleDraft,
    structuredData: SEOStructuredDataPreview
  ) -> [SEOAuditFinding] {
    var findings: [SEOAuditFinding] = []

    if title.count > 60 {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: "社交标题可能截断",
          message: "当前 \(title.count) 字，建议控制在 60 字以内。",
          field: "title"
        )
      )
    }

    if description.count < 50 {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: "社交描述偏短",
          message: "当前 \(description.count) 字，建议补足结论、场景或价值。",
          field: "summary"
        )
      )
    } else if description.count > 200 {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: "社交描述可能截断",
          message: "当前 \(description.count) 字，建议控制在 200 字以内。",
          field: "summary"
        )
      )
    }

    if imagePath == nil && !draft.isPrivate {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: "缺少社交预览图",
          message: "Open Graph 和 Twitter/X 卡片会缺少图片。",
          field: "cover"
        )
      )
    }

    if imagePath != nil,
       imageAltText?.trimmedForPublishing.nilIfEmpty == nil,
       !draft.isPrivate {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: "社交预览图缺少 Alt",
          message: "建议为封面图补充 Alt 文本，以输出 og:image:alt 和 twitter:image:alt。",
          field: "coverAlt"
        )
      )
    }

    if !draft.isPrivate,
       let cover = coverAttachment(for: draft),
       let dimensions = imageDimensions(for: cover) {
      if dimensions.width < 1200 || dimensions.height < 628 {
        findings.append(
          SEOAuditFinding(
            severity: .warning,
            title: "社交预览图尺寸偏小",
            message: "当前 \(dimensions.displayName)，Open Graph / Twitter 大图建议至少 1200x630 左右。",
            field: "cover"
          )
        )
      }
    }

    if findings.isEmpty {
      findings.append(
        SEOAuditFinding(
          severity: .info,
          title: "社交预览字段完整",
          message: "标题、描述和预览图都可用于生成社交卡片。",
          field: nil
        )
      )
    }

    switch structuredData.status {
    case .missing:
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: "JSON-LD 缺少字段",
          message: structuredData.message,
          field: "jsonLD"
        )
      )
    case .warning:
      findings.append(
        SEOAuditFinding(
          severity: .info,
          title: "JSON-LD 需确认",
          message: structuredData.message,
          field: "jsonLD"
        )
      )
    case .ready:
      findings.append(
        SEOAuditFinding(
          severity: .info,
          title: "JSON-LD 已生成",
          message: "Article 结构化数据可复制到发布模板。",
          field: "jsonLD"
        )
      )
    }

    return findings
  }
}
