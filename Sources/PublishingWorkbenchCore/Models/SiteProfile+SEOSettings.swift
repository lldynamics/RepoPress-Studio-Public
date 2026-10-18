import Foundation

public enum SEOSharingImageSource: String, Codable, Hashable, Sendable {
  case articleCover
  case siteDefault
  case unavailableArticleCover
  case invalidSiteDefault
  case privateArticle
  case none
  case unknown

  public var displayName: String {
    switch self {
    case .articleCover: return CoreL10n.text("本文封面")
    case .siteDefault: return CoreL10n.text("站点默认分享图")
    case .unavailableArticleCover: return CoreL10n.text("本文封面不可用")
    case .invalidSiteDefault: return CoreL10n.text("站点默认分享图路径无效")
    case .privateArticle: return CoreL10n.text("私密文章不输出图片")
    case .none: return CoreL10n.text("未设置分享图")
    case .unknown: return CoreL10n.text("旧快照未记录来源")
    }
  }
}

struct SEOSharingImageResolution: Sendable {
  let path: String?
  let altText: String?
  let attachment: DraftAttachment?
  let source: SEOSharingImageSource
  let articleIntent: SEOArticleSocialImageIntent?
}

public enum ThemeTitleH1ResolutionSource: String, Codable, Hashable, Sendable {
  case siteOverride
  case localTemplate
  case unknown

  public var displayName: String {
    switch self {
    case .siteOverride:
      return CoreL10n.text("站点明确设置")
    case .localTemplate:
      return CoreL10n.text("本地模板检查")
    case .unknown:
      return CoreL10n.text("尚未确认")
    }
  }
}

public struct ThemeTitleH1Resolution: Codable, Hashable, Sendable {
  public let providesTitleH1: Bool?
  public let source: ThemeTitleH1ResolutionSource

  public init(providesTitleH1: Bool?, source: ThemeTitleH1ResolutionSource) {
    self.providesTitleH1 = providesTitleH1
    self.source = source
  }

  public var displayName: String {
    switch providesTitleH1 {
    case true:
      return CoreL10n.text("主题提供页面 H1")
    case false:
      return CoreL10n.text("主题不提供页面 H1")
    case nil:
      return CoreL10n.text("主题 H1 状态未知")
    }
  }
}

extension SiteProfile {
  /// Resolve the theme fact independently from the user's warning switch.
  /// Template inspection runs off the main actor, never from a SwiftUI getter.
  public func resolveThemeTitleH1(repositoryRevision: UUID) async -> ThemeTitleH1Resolution {
    if let themeProvidesTitleH1 {
      return ThemeTitleH1Resolution(
        providesTitleH1: themeProvidesTitleH1,
        source: .siteOverride
      )
    }
    let profile = self
    let detected = await Task.detached(priority: .utility) {
      ThemeTitleH1Detector().cachedOrDetect(
        profile: profile,
        repositoryRevision: repositoryRevision
      )
    }.value
    return ThemeTitleH1Resolution(
      providesTitleH1: detected,
      source: detected == nil ? .unknown : .localTemplate
    )
  }

  /// The editor stays conservative while the theme fact is unknown, but a
  /// disabled warning preference always wins.
  public func resolveBodyH1DuplicateWarning(repositoryRevision: UUID) async -> Bool {
    guard resolvedWarnsWhenBodyH1DuplicatesTitle else { return false }
    let resolution = await resolveThemeTitleH1(repositoryRevision: repositoryRevision)
    return resolution.providesTitleH1 != false
  }

  public var resolvedWarnsWhenBodyH1DuplicatesTitle: Bool {
    get { warnsWhenBodyH1DuplicatesTitle ?? true }
    set { warnsWhenBodyH1DuplicatesTitle = newValue }
  }

  public func seoArticleSocialImageIntent(
    for draftID: UUID
  ) -> SEOArticleSocialImageIntent? {
    seoArticleSocialImagePreferences?.first { $0.draftID == draftID }?.intent
  }

  public var resolvedDefaultSocialImagePath: String? {
    defaultSocialImagePath?.trimmedForPublishing.nilIfEmpty
  }

  public var resolvedDefaultSocialImageAltText: String? {
    defaultSocialImageAltText?.trimmedForPublishing.nilIfEmpty
  }

  func seoSharingImageResolution(for draft: ArticleDraft) -> SEOSharingImageResolution {
    let articleIntent = seoArticleSocialImageIntent(for: draft.id)
    guard !draft.isPrivate else {
      return SEOSharingImageResolution(
        path: nil,
        altText: nil,
        attachment: nil,
        source: .privateArticle,
        articleIntent: articleIntent
      )
    }

    if let coverID = draft.coverAttachmentID {
      guard let cover = draft.attachments.first(where: { $0.id == coverID }),
        let path = cover.relativePublishPath.trimmedForPublishing.nilIfEmpty
      else {
        // A selected article cover is authoritative. Falling back here would
        // hide a broken selection behind the site's default image.
        return SEOSharingImageResolution(
          path: nil,
          altText: nil,
          attachment: nil,
          source: .unavailableArticleCover,
          articleIntent: articleIntent
        )
      }
      return SEOSharingImageResolution(
        path: path,
        altText: cover.altText.trimmedForPublishing.nilIfEmpty,
        attachment: cover,
        source: .articleCover,
        articleIntent: articleIntent
      )
    }

    if let defaultPath = resolvedDefaultSocialImagePath {
      guard Self.isValidDefaultSocialImagePath(defaultPath) else {
        return SEOSharingImageResolution(
          path: nil,
          altText: nil,
          attachment: nil,
          source: .invalidSiteDefault,
          articleIntent: articleIntent
        )
      }
      return SEOSharingImageResolution(
        path: defaultPath,
        altText: resolvedDefaultSocialImageAltText,
        attachment: nil,
        source: .siteDefault,
        articleIntent: articleIntent
      )
    }

    return SEOSharingImageResolution(
      path: nil,
      altText: nil,
      attachment: nil,
      source: .none,
      articleIntent: articleIntent
    )
  }

  private static func isValidDefaultSocialImagePath(_ path: String) -> Bool {
    if path.hasPrefix("/"), !path.hasPrefix("//") { return path.count > 1 }
    guard let url = URL(string: path),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else { return false }
    return url.host?.isEmpty == false
  }
}

extension SEOSocialPreviewService {
  func socialPreviewFindings(
    title: String,
    description: String,
    imagePath: String?,
    imageAltText: String?,
    imageDimensions: ImageDimensions?,
    imageSource: SEOSharingImageSource,
    articleImageIntent: SEOArticleSocialImageIntent?,
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

    if imageSource == .unavailableArticleCover {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: CoreL10n.text("所选封面不可用于社交预览"),
          message: CoreL10n.text("本文已选择封面，但对应附件不存在或缺少公开路径；站点默认图不会掩盖这个问题。"),
          field: "cover"
        )
      )
    } else if imageSource == .invalidSiteDefault {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: CoreL10n.text("站点默认分享图路径无效"),
          message: CoreL10n.text("请使用以 / 开头的公开路径，或完整的 http/https URL。"),
          field: "cover"
        )
      )
    } else if imagePath == nil,
      !draft.isPrivate,
      articleImageIntent != .noIndividualImage
    {
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
      !draft.isPrivate
    {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: "社交预览图缺少 Alt",
          message: "建议为封面图补充 Alt 文本，以输出 og:image:alt 和 twitter:image:alt。",
          field: "coverAlt"
        )
      )
    }
    if !draft.isPrivate, let dimensions = imageDimensions,
      dimensions.width < 1200 || dimensions.height < 628
    {
      findings.append(
        SEOAuditFinding(
          severity: .warning,
          title: "社交预览图尺寸偏小",
          message: "当前 \(dimensions.displayName)，Open Graph / Twitter 大图建议至少 1200x630 左右。",
          field: "cover"
        )
      )
    }

    if findings.isEmpty {
      let completionMessage: String
      switch imageSource {
      case .privateArticle:
        completionMessage = CoreL10n.text("标题和描述可用于生成私密文章预览；不会输出分享图。")
      case .none where articleImageIntent == .noIndividualImage:
        completionMessage = CoreL10n.text("标题和描述可用于生成社交卡片；本文已明确不单独配图。")
      default:
        completionMessage = "标题、描述和预览图都可用于生成社交卡片。"
      }
      findings.append(
        SEOAuditFinding(
          severity: .info,
          title: "社交预览字段完整",
          message: completionMessage
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
