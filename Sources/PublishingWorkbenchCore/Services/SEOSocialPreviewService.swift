import CoreGraphics
import Foundation
import ImageIO

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
