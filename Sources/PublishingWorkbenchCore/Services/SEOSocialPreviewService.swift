import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PublishingDomainContracts

public struct SEOSocialPreviewService: Sendable {
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
      draft: draft,
      profile: profile,
      localPreviewURL: localPreviewURL
    )
    let sharingImage = profile.seoSharingImageResolution(for: draft)
    let imagePath = sharingImage.path
    let imageAltText = sharingImage.altText
    let imageDimensions = sharingImage.attachment.flatMap(imageDimensions(for:))
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
      shouldWarnWhenImageMissing: !draft.isPrivate
        && !(sharingImage.articleIntent == .noIndividualImage && sharingImage.source == .none),
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
      imageSource: sharingImage.source,
      articleImageIntent: sharingImage.articleIntent,
      socialImageURLText: imageURLText,
      imageDimensions: imageDimensions,
      imageAltText: imageAltText,
      shareHashtags: shareHashtags(for: draft),
      cards: cards,
      metaTags: metaTags,
      structuredData: structuredData,
      findings: socialPreviewFindings(
        title: title,
        description: description,
        imagePath: imagePath,
        imageAltText: imageAltText,
        imageDimensions: imageDimensions,
        imageSource: sharingImage.source,
        articleImageIntent: sharingImage.articleIntent,
        draft: draft,
        structuredData: structuredData
      ),
      generatedAt: Date()
    )
  }

  public func signature(
    draft: ArticleDraft,
    profile: SiteProfile,
    localPreviewURL: URL? = nil
  ) -> String {
    let cover = coverAttachment(for: draft)
    let sharingImage = profile.seoSharingImageResolution(for: draft)
    let dimensions = sharingImage.attachment.flatMap(imageDimensions(for:))
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
      sharingImage.source.rawValue,
      sharingImage.articleIntent?.rawValue ?? "",
      profile.defaultSocialImagePath ?? "",
      profile.defaultSocialImageAltText ?? "",
      profile.themeProvidesTitleH1.map { String($0) } ?? "unknown",
      profile.warnsWhenBodyH1DuplicatesTitle.map { String($0) } ?? "default",
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
    let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
    return Data(digest).base64EncodedString()
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
    draft: ArticleDraft,
    profile: SiteProfile,
    localPreviewURL: URL?
  ) -> String {
    let resolver = SiteArticleURLResolver()
    let markdownPath = profile.markdownPath(for: draft)
    let relativeURLPath = resolver.relativeWebPath(
      from: markdownPath,
      profile: profile,
      permalink: draft.permalink
    )
    let profileDeploymentURL = profile.deploymentSiteURL
      .flatMap { URL(string: $0.trimmedForPublishing) }
      .flatMap { url in
        url.scheme != nil && url.host != nil ? url : nil
      }
    if let baseURL = localPreviewURL ?? profileDeploymentURL {
      return resolver.url(
        baseURL: baseURL,
        markdownPath: markdownPath,
        profile: profile,
        permalink: draft.permalink
      )?.absoluteString ?? relativeURLPath
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

  private func structuredDataPreview(
    title: String,
    description: String,
    canonicalURLText: String,
    imageURLText: String?,
    shouldWarnWhenImageMissing: Bool,
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
    if imageURLText == nil && shouldWarnWhenImageMissing {
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

}
