import CryptoKit
import Foundation
import PublishingWorkbenchCore

enum RSSArticleHTMLRenderer {
  private struct SanitizedBody {
    let html: String
    let hasRenderableContent: Bool
    let readableSample: String
    let readingUnits: Int
  }

  private struct SanitizedTag {
    let html: String
    let hasRenderableContent: Bool

    static let empty = SanitizedTag(html: "", hasRenderableContent: false)
  }

  private static let allowedTags: Set<String> = [
    "a", "article", "b", "blockquote", "br", "code", "del", "details", "div",
    "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
    "i", "li", "main", "mark", "ol", "p", "pre", "s", "section", "small",
    "span", "strong", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
    "tr", "u", "ul",
  ]
  private static let voidTags: Set<String> = ["br", "hr", "img"]
  private static let commentExpression = try? NSRegularExpression(
    pattern: "<!--[\\s\\S]*?-->",
    options: [.caseInsensitive]
  )
  private static let dangerousBlockExpression = try? NSRegularExpression(
    pattern:
      "<(script|style|iframe|object|embed|form|svg|math|noscript|template)\\b[^>]*>(?:[\\s\\S]*?</\\1\\s*>|[\\s\\S]*$)",
    options: [.caseInsensitive]
  )
  private static let dangerousVoidExpression = try? NSRegularExpression(
    pattern: "<(script|style|iframe|object|embed|form|svg|math|noscript|template)\\b[^>]*/\\s*>",
    options: [.caseInsensitive]
  )
  private static let tagTokenExpression = try? NSRegularExpression(
    pattern: "<[^>]*>",
    options: [.caseInsensitive]
  )
  private static let closingTagExpression = try? NSRegularExpression(
    pattern: "^<\\s*/\\s*([a-z0-9]+)[^>]*>$",
    options: [.caseInsensitive]
  )
  private static let openingTagExpression = try? NSRegularExpression(
    pattern: "^<\\s*([a-z0-9]+)([\\s\\S]*?)>\\s*$",
    options: [.caseInsensitive]
  )
  private static let whitespaceEntityExpression = try? NSRegularExpression(
    pattern:
      "&(?:nbsp|zwnj|zwj|zerowidthspace|#0*(?:160|8203|8204|8205|65279)|#x0*(?:a0|200b|200c|200d|feff));",
    options: [.caseInsensitive]
  )
  private static let attributeEntityExpression = try? NSRegularExpression(
    pattern: "&(?:amp|quot|apos|lt|gt|#\\d+|#x[0-9a-f]+);",
    options: [.caseInsensitive]
  )
  private static let unsafeAmpersandExpression = try? NSRegularExpression(
    pattern: "&(?!(?:#\\d+|#x[0-9a-f]+|[a-z][a-z0-9]+);)",
    options: [.caseInsensitive]
  )

  final class RSSArticleRenderCache: @unchecked Sendable {
    static let shared = RSSArticleRenderCache()
    static let defaultCostLimit = 4 * 1024 * 1024

    private struct Entry {
      let html: String
      let byteCost: Int
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var keys: [String] = []
    private let costLimit: Int
    private var currentCost = 0

    init(costLimit: Int = RSSArticleRenderCache.defaultCostLimit) {
      self.costLimit = max(1, costLimit)
    }

    func html(forKey key: String) -> String? {
      lock.lock()
      defer { lock.unlock() }
      guard let entry = cache[key] else { return nil }
      touch(key)
      return entry.html
    }

    func setHTML(_ html: String, forKey key: String) {
      lock.lock()
      defer { lock.unlock() }
      let byteCost = html.utf8.count
      if let previous = cache.removeValue(forKey: key) {
        currentCost -= previous.byteCost
        keys.removeAll { $0 == key }
      }
      guard byteCost <= costLimit else {
        return
      }
      while currentCost + byteCost > costLimit, let oldest = keys.first {
        keys.removeFirst()
        if let removed = cache.removeValue(forKey: oldest) {
          currentCost -= removed.byteCost
        }
      }
      keys.append(key)
      cache[key] = Entry(html: html, byteCost: byteCost)
      currentCost += byteCost
    }

    func invalidate(articleID: String) {
      lock.lock()
      defer { lock.unlock() }
      let matchingKeys = cache.keys.filter { $0.hasPrefix("\(articleID)|") }
      for key in matchingKeys {
        if let removed = cache.removeValue(forKey: key) {
          currentCost -= removed.byteCost
        }
      }
      keys.removeAll { matchingKeys.contains($0) }
    }

    var byteCost: Int {
      lock.lock()
      defer { lock.unlock() }
      return currentCost
    }

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return cache.count
    }

    func clear() {
      lock.lock()
      defer { lock.unlock() }
      cache.removeAll()
      keys.removeAll()
      currentCost = 0
    }

    private func touch(_ key: String) {
      keys.removeAll { $0 == key }
      keys.append(key)
    }
  }

  private static let renderCacheKeyVersion = 1

  static func render(
    article: RSSArticle,
    feedTitle: String? = nil,
    readingMinutes: Int? = nil,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset] = [],
    mediaCacheDirectoryURL: URL? = nil,
    fontSize: Double = RSSReadingComfortConfiguration.defaultFontSize,
    lineSpacing: Double = RSSReadingComfortConfiguration.defaultLineSpacing,
    theme: RSSReadingTheme = .system,
    initialReadingProgress: Double = 0
  ) -> String {
    let cacheKey = renderCacheKey(
      article: article,
      feedTitle: feedTitle,
      readingMinutes: readingMinutes,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL,
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      theme: theme,
      initialReadingProgress: initialReadingProgress
    )
    if let cached = RSSArticleRenderCache.shared.html(forKey: cacheKey) {
      return cached
    }

    let body = preferredSanitizedBody(
      for: article,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL
    )
    let rendered = renderDocument(
      title: article.title,
      feedTitle: feedTitle,
      author: article.author,
      publishedAt: article.publishedAt,
      readingMinutes: readingMinutes,
      body: body.html,
      languageTag: RSSArticleLanguageResolver.languageTag(
        for: "\(article.title) \(body.readableSample)"
      ),
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      theme: theme,
      initialReadingProgress: initialReadingProgress
    )
    RSSArticleRenderCache.shared.setHTML(rendered, forKey: cacheKey)
    return rendered
  }

  static func renderCacheKey(
    article: RSSArticle,
    feedTitle: String?,
    readingMinutes: Int?,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset],
    mediaCacheDirectoryURL: URL?,
    fontSize: Double,
    lineSpacing: Double,
    theme: RSSReadingTheme,
    initialReadingProgress: Double
  ) -> String {
    let mediaToken = mediaAssets.map { asset in
      "\(stableStringToken(asset.id)):\(stableStringToken(asset.relativePath))"
    }.joined(separator: ",")
    let identity = [
      "version=\(renderCacheKeyVersion)",
      "article.id=\(stableStringToken(article.id))",
      "article.link=\(stableStringToken(article.link?.absoluteString))",
      "article.title=\(stableStringToken(article.title))",
      "article.author=\(stableStringToken(article.author))",
      "article.publishedAt=\(stableDateToken(article.publishedAt))",
      "article.summaryHTML=\(stableStringToken(article.summaryHTML))",
      "article.contentHTML=\(stableStringToken(article.contentHTML))",
      "article.webPageSnapshotHTML=\(stableStringToken(article.webPageSnapshotHTML))",
      "article.fetchedAt=\(stableDateToken(article.fetchedAt))",
      "feedTitle=\(stableStringToken(feedTitle))",
      "readingMinutes=\(readingMinutes.map(String.init) ?? "nil")",
      "allowRemoteImages=\(allowRemoteImages ? "true" : "false")",
      "fontSize=\(fontSize.bitPattern)",
      "lineSpacing=\(lineSpacing.bitPattern)",
      "theme=\(theme.rawValue)",
      "initialReadingProgress=\(initialReadingProgress.bitPattern)",
      "mediaCacheDirectoryURL=\(stableStringToken(mediaCacheDirectoryURL?.absoluteString))",
      "mediaToken=\(mediaToken)",
    ].joined(separator: "\u{001F}")
    let digest = SHA256.hash(data: Data(identity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(article.id)|v\(renderCacheKeyVersion)|\(digest)"
  }

  private static func stableStringToken(_ value: String?) -> String {
    guard let value else { return "nil" }
    return "\(value.utf8.count):\(value)"
  }

  private static func stableDateToken(_ value: Date?) -> String {
    guard let value else { return "nil" }
    return String(value.timeIntervalSince1970.bitPattern)
  }

  static func hasRenderableBody(article: RSSArticle) -> Bool {
    preferredSanitizedBody(
      for: article,
      allowRemoteImages: false,
      mediaAssets: [],
      mediaCacheDirectoryURL: nil
    ).hasRenderableContent
  }

  static func bodyMetrics(article: RSSArticle) -> (
    hasRenderableBody: Bool,
    readingUnits: Int
  ) {
    let body = preferredSanitizedBody(
      for: article,
      allowRemoteImages: false,
      mediaAssets: [],
      mediaCacheDirectoryURL: nil
    )
    return (body.hasRenderableContent, body.readingUnits)
  }

  static func render(
    source: String,
    baseURL: URL?,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset] = [],
    mediaCacheDirectoryURL: URL? = nil,
    languageTag: String = "und",
    fontSize: Double = RSSReadingComfortConfiguration.defaultFontSize,
    lineSpacing: Double = RSSReadingComfortConfiguration.defaultLineSpacing,
    theme: RSSReadingTheme = .system,
    initialReadingProgress: Double = 0
  ) -> String {
    let body = sanitizedBody(
      source: source,
      baseURL: baseURL,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL
    )
    return renderDocument(
      body: body.html,
      languageTag: languageTag,
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      theme: theme,
      initialReadingProgress: initialReadingProgress
    )
  }

  private static func renderDocument(
    title: String? = nil,
    feedTitle: String? = nil,
    author: String? = nil,
    publishedAt: Date? = nil,
    readingMinutes: Int? = nil,
    body: String,
    languageTag: String,
    fontSize: Double,
    lineSpacing: Double,
    theme: RSSReadingTheme,
    initialReadingProgress: Double
  ) -> String {
    let normalizedFontSize = min(
      max(
        fontSize.isFinite ? fontSize : RSSReadingComfortConfiguration.defaultFontSize,
        RSSReadingComfortConfiguration.fontSizeRange.lowerBound),
      RSSReadingComfortConfiguration.fontSizeRange.upperBound
    )
    let normalizedLineSpacing = min(
      max(
        lineSpacing.isFinite ? lineSpacing : RSSReadingComfortConfiguration.defaultLineSpacing,
        RSSReadingComfortConfiguration.lineSpacingRange.lowerBound),
      RSSReadingComfortConfiguration.lineSpacingRange.upperBound
    )
    let normalizedProgress = min(
      max(initialReadingProgress.isFinite ? initialReadingProgress : 0, 0), 1)

    var headerHTML = ""
    if let title, !title.isEmpty {
      var metaItems: [String] = []
      if let feedTitle, !feedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        metaItems.append(
          "<span class=\"rss-meta-item\">\(escapeText(feedTitle.trimmingCharacters(in: .whitespacesAndNewlines)))</span>"
        )
      }
      if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        metaItems.append(
          "<span class=\"rss-meta-item\">\(escapeText(author.trimmingCharacters(in: .whitespacesAndNewlines)))</span>"
        )
      }
      if let publishedAt {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        metaItems.append(
          "<span class=\"rss-meta-item\">\(escapeText(formatter.string(from: publishedAt)))</span>")
      }
      if let readingMinutes, readingMinutes > 0 {
        metaItems.append("<span class=\"rss-meta-item\">约 \(readingMinutes) 分钟读完</span>")
      }

      let metaHTML =
        metaItems.isEmpty
        ? ""
        : """
          <div class="rss-article-meta">
            \(metaItems.joined(separator: " · "))
          </div>
        """

      headerHTML = """
        <header class="rss-article-header">
          <h1 class="rss-article-title">\(escapeText(title))</h1>
          \(metaHTML)
        </header>
        <hr class="rss-header-divider" />
        """
    }

    return """
      <!doctype html>
      <html lang="\(escapeAttribute(languageTag))">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src https: http: file:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';">
        <style>
          :root { color-scheme: \(theme.cssColorScheme); --rss-font-size: \(normalizedFontSize)px; --rss-line-spacing: \(normalizedLineSpacing); --rss-background: \(theme.cssBackground); --rss-foreground: \(theme.cssForeground); --rss-secondary-foreground: \(theme.cssSecondaryForeground); --rss-link: \(theme.cssLink); }
          html, body { width: 100%; max-width: 100%; min-height: 100%; overflow-x: hidden; }
          body { display: block; visibility: visible; opacity: 1; margin: 0; min-height: 100vh; padding: 4px 2px 28px; box-sizing: border-box; color: var(--rss-foreground) !important; background: var(--rss-background) !important; font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; font-size: var(--rss-font-size); line-height: var(--rss-line-spacing); overflow-wrap: anywhere; -webkit-text-fill-color: var(--rss-foreground); }
          #rss-article-container { display: block; width: 100%; max-width: 780px; min-width: 0; margin: 0 auto; padding: 72px 24px 48px; box-sizing: border-box; overflow-x: hidden; visibility: visible; opacity: 1; color: var(--rss-foreground) !important; }
          #rss-article-body { display: block; width: 100%; min-width: 0; overflow-x: hidden; visibility: visible; opacity: 1; color: var(--rss-foreground) !important; }
          .rss-article-header { margin: 0 0 1.2em 0; }
          .rss-article-title { font-size: 1.85em; font-weight: 700; line-height: 1.3; margin: 0 0 0.4em 0; color: var(--rss-foreground); overflow-wrap: break-word; -webkit-text-fill-color: var(--rss-foreground); }
          .rss-article-meta { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 12px; font-size: 0.88em; color: var(--rss-secondary-foreground); -webkit-text-fill-color: var(--rss-secondary-foreground); margin-bottom: 0.4em; }
          .rss-meta-item { display: inline-flex; align-items: center; gap: 4px; }
          .rss-header-divider { border: 0; border-top: 1px solid rgba(127, 127, 127, 0.28); margin: 1em 0 1.5em 0; }
          h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.1em 0 0.55em; }
          p, div, article, section, blockquote, pre, ul, ol, table, figure, details { margin: 0.75em 0; }
          ul, ol { padding-left: 1.6em; }
          blockquote { margin-left: 0; padding: 0.1em 1em; border-left: 3px solid var(--rss-secondary-foreground); color: var(--rss-secondary-foreground); }
          figure { margin-left: 0; margin-right: 0; }
          figcaption, small { color: var(--rss-secondary-foreground); }
          figcaption { margin-top: 0.4em; font-size: 0.9em; }
          hr { border: 0; border-top: 1px solid rgba(127, 127, 127, 0.35); margin: 1.25em 0; }
          summary { cursor: pointer; font-weight: 600; }
          pre { max-width: 100%; padding: 0.85em 1em; border-radius: 8px; background: rgba(127, 127, 127, 0.14); overflow-x: auto; overflow-wrap: anywhere; white-space: pre-wrap; }
          code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }
          table { border-collapse: collapse; width: 100%; max-width: 100%; table-layout: fixed; }
          th, td { border: 1px solid rgba(127, 127, 127, 0.35); padding: 0.35em 0.55em; text-align: left; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; }
          a { color: var(--rss-link); }
          img, video, iframe, svg, canvas { max-width: 100%; height: auto; }
          img { height: auto; border-radius: 8px; }
          .remote-image-disabled { display: inline-block; padding: 0.55em 0.8em; border: 1px dashed var(--rss-secondary-foreground); border-radius: 7px; color: var(--rss-secondary-foreground); }
          mark.rss-highlight { background: color-mix(in srgb, #ffd60a 55%, transparent); color: inherit; border-radius: 3px; padding: 0 2px; }
          mark.rss-speech-highlight { background: color-mix(in srgb, #0a84ff 32%, transparent); color: inherit; border-radius: 3px; padding: 0 2px; box-shadow: inset 0 -1px 0 color-mix(in srgb, #0a84ff 72%, transparent); }
            \(ThinRedScrollbarWebStyle.css)
        </style>
      </head>
      <body data-initial-reading-progress="\(normalizedProgress)"><article id="rss-article-container">\(headerHTML)<main id="rss-article-body">\(body)</main></article></body>
      </html>
      """
  }

  private static func preferredSanitizedBody(
    for article: RSSArticle,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset],
    mediaCacheDirectoryURL: URL?
  ) -> SanitizedBody {
    let content = sanitizedBody(
      source: article.contentHTML,
      baseURL: article.link,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL
    )
    guard !content.hasRenderableContent else { return content }
    let summary = sanitizedBody(
      source: article.summaryHTML,
      baseURL: article.link,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL
    )
    if summary.hasRenderableContent { return summary }
    let snapshot = sanitizedBody(
      source: article.webPageSnapshotHTML ?? "",
      baseURL: article.link,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL
    )
    return snapshot.hasRenderableContent ? snapshot : content
  }

  private static func sanitizedBody(
    source: String,
    baseURL: URL?,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset],
    mediaCacheDirectoryURL: URL?
  ) -> SanitizedBody {
    let withoutComments = replacingMatches(
      in: source,
      using: commentExpression,
      with: " "
    )
    let withoutDangerousBlocks = replacingMatches(
      in: replacingMatches(
        in: withoutComments,
        using: dangerousVoidExpression,
        with: " "
      ),
      using: dangerousBlockExpression,
      with: " "
    )

    let sourceRange = NSRange(withoutDangerousBlocks.startIndex..., in: withoutDangerousBlocks)
    var output = ""
    var cursor = withoutDangerousBlocks.startIndex
    var hasRenderableContent = false
    var readableSample = ""
    var latinWords = 0
    var cjkCharacters = 0

    func appendText(_ source: String) {
      output += escapeText(source)
      let visibleText = normalizedVisibleText(source)
      guard !visibleText.isEmpty else { return }
      hasRenderableContent = true
      latinWords += visibleText.split { $0.isWhitespace || $0.isPunctuation }.count
      cjkCharacters +=
        visibleText.unicodeScalars.filter { scalar in
          switch scalar.value {
          case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            true
          default:
            false
          }
        }.count
      guard readableSample.count < 512 else { return }
      let separator = readableSample.isEmpty ? "" : " "
      let remaining = max(0, 512 - readableSample.count - separator.count)
      readableSample += separator + String(visibleText.prefix(remaining))
    }

    tagTokenExpression?.enumerateMatches(in: withoutDangerousBlocks, range: sourceRange) {
      match, _, _ in
      guard let match else { return }
      let tokenRange = Range(match.range, in: withoutDangerousBlocks)!
      if cursor < tokenRange.lowerBound {
        appendText(String(withoutDangerousBlocks[cursor..<tokenRange.lowerBound]))
      }
      let tag = sanitizeTag(
        String(withoutDangerousBlocks[tokenRange]),
        baseURL: baseURL,
        allowRemoteImages: allowRemoteImages,
        mediaAssets: mediaAssets,
        mediaCacheDirectoryURL: mediaCacheDirectoryURL
      )
      output += tag.html
      hasRenderableContent = hasRenderableContent || tag.hasRenderableContent
      cursor = tokenRange.upperBound
    }

    if cursor < withoutDangerousBlocks.endIndex {
      appendText(String(withoutDangerousBlocks[cursor...]))
    }

    let html = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return SanitizedBody(
      html: html,
      hasRenderableContent: hasRenderableContent,
      readableSample: readableSample,
      readingUnits: max(latinWords, cjkCharacters)
    )
  }

  private static func sanitizeTag(
    _ source: String,
    baseURL: URL?,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset],
    mediaCacheDirectoryURL: URL?
  ) -> SanitizedTag {
    if let match = closingTagExpression?.firstMatch(
      in: source,
      range: NSRange(source.startIndex..., in: source)
    ), let nameRange = Range(match.range(at: 1), in: source) {
      let name = source[nameRange].lowercased()
      let html =
        allowedTags.contains(name) && !voidTags.contains(name)
        ? "</\(outputTagName(for: name))>"
        : ""
      return SanitizedTag(html: html, hasRenderableContent: false)
    }

    guard
      let match = openingTagExpression?.firstMatch(
        in: source,
        range: NSRange(source.startIndex..., in: source)
      ), let nameRange = Range(match.range(at: 1), in: source),
      let attributesRange = Range(match.range(at: 2), in: source)
    else {
      return .empty
    }

    let name = source[nameRange].lowercased()
    let attributes = parseAttributes(String(source[attributesRange]))
    if name == "img" {
      let altText = attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard
        let rawURL = attributes["src"]
          ?? attributes["data-src"]
          ?? attributes["data-original"],
        let imageURL = validatedRemoteURL(rawURL, relativeTo: baseURL)
      else {
        guard !altText.isEmpty else { return .empty }
        return SanitizedTag(
          html: "<span>\(escapeText(altText))</span>",
          hasRenderableContent: true
        )
      }
      let alt = escapeAttribute(altText)
      if let localURL = archivedImageURL(
        for: imageURL,
        mediaAssets: mediaAssets,
        mediaCacheDirectoryURL: mediaCacheDirectoryURL
      ) {
        return SanitizedTag(
          html:
            "<img src=\"\(escapeAttribute(localURL.absoluteString))\" alt=\"\(alt)\" loading=\"lazy\">",
          hasRenderableContent: true
        )
      }
      guard allowRemoteImages else {
        return SanitizedTag(
          html: "<span class=\"remote-image-disabled\">远程图片已关闭，可点击“加载远程图片”查看</span>",
          hasRenderableContent: true
        )
      }
      return SanitizedTag(
        html:
          "<img src=\"\(escapeAttribute(imageURL.absoluteString))\" alt=\"\(alt)\" loading=\"lazy\" referrerpolicy=\"no-referrer\">",
        hasRenderableContent: true
      )
    }
    guard allowedTags.contains(name) else { return .empty }
    if name == "br" || name == "hr" {
      return SanitizedTag(html: "<\(name)>", hasRenderableContent: false)
    }
    if name == "a", let rawURL = attributes["href"],
      let linkURL = validatedLinkURL(rawURL, relativeTo: baseURL)
    {
      return SanitizedTag(
        html: "<a href=\"\(escapeAttribute(linkURL.absoluteString))\" rel=\"noopener noreferrer\">",
        hasRenderableContent: false
      )
    }
    return SanitizedTag(
      html: "<\(outputTagName(for: name))>",
      hasRenderableContent: false
    )
  }

  private static func outputTagName(for sourceName: String) -> String {
    sourceName == "main" ? "div" : sourceName
  }

  private static func parseAttributes(_ source: String) -> [String: String] {
    var result: [String: String] = [:]
    var cursor = source.startIndex

    func isNameCharacter(_ character: Character) -> Bool {
      character.isLetter || character.isNumber || "_:-".contains(character)
    }

    while cursor < source.endIndex {
      while cursor < source.endIndex,
        source[cursor].isWhitespace || source[cursor] == "/"
      {
        cursor = source.index(after: cursor)
      }
      guard cursor < source.endIndex else { break }

      let nameStart = cursor
      while cursor < source.endIndex, isNameCharacter(source[cursor]) {
        cursor = source.index(after: cursor)
      }
      guard nameStart < cursor else {
        cursor = source.index(after: cursor)
        continue
      }
      let name = String(source[nameStart..<cursor]).lowercased()
      while cursor < source.endIndex, source[cursor].isWhitespace {
        cursor = source.index(after: cursor)
      }
      guard cursor < source.endIndex, source[cursor] == "=" else {
        continue
      }
      cursor = source.index(after: cursor)
      while cursor < source.endIndex, source[cursor].isWhitespace {
        cursor = source.index(after: cursor)
      }
      guard cursor < source.endIndex else {
        result[name] = ""
        break
      }

      let value: String
      if source[cursor] == "\"" || source[cursor] == "'" {
        let quote = source[cursor]
        cursor = source.index(after: cursor)
        let valueStart = cursor
        while cursor < source.endIndex, source[cursor] != quote {
          cursor = source.index(after: cursor)
        }
        value = String(source[valueStart..<cursor])
        if cursor < source.endIndex { cursor = source.index(after: cursor) }
      } else {
        let valueStart = cursor
        while cursor < source.endIndex,
          !source[cursor].isWhitespace, source[cursor] != ">"
        {
          cursor = source.index(after: cursor)
        }
        value = String(source[valueStart..<cursor])
      }
      if result[name] == nil { result[name] = decodeAttributeEntities(value) }
    }
    return result
  }

  private static func replacingMatches(
    in source: String,
    using expression: NSRegularExpression?,
    with replacement: String
  ) -> String {
    guard let expression else { return source }
    return expression.stringByReplacingMatches(
      in: source,
      range: NSRange(source.startIndex..., in: source),
      withTemplate: replacement
    )
  }

  private static func normalizedVisibleText(_ source: String) -> String {
    replacingMatches(
      in: source,
      using: whitespaceEntityExpression,
      with: " "
    )
    .replacingOccurrences(of: "\u{200B}", with: "")
    .replacingOccurrences(of: "\u{200C}", with: "")
    .replacingOccurrences(of: "\u{200D}", with: "")
    .replacingOccurrences(of: "\u{FEFF}", with: "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func decodeAttributeEntities(_ source: String) -> String {
    guard let attributeEntityExpression else { return source }
    let sourceRange = NSRange(source.startIndex..., in: source)
    var output = ""
    var cursor = source.startIndex
    attributeEntityExpression.enumerateMatches(in: source, range: sourceRange) { match, _, _ in
      guard let match, let range = Range(match.range, in: source) else { return }
      output += source[cursor..<range.lowerBound]
      let entity = String(source[range]).lowercased()
      output += decodedEntity(entity) ?? String(source[range])
      cursor = range.upperBound
    }
    output += source[cursor...]
    return output
  }

  private static func decodedEntity(_ entity: String) -> String? {
    switch entity {
    case "&amp;": return "&"
    case "&quot;": return "\""
    case "&apos;": return "'"
    case "&lt;": return "<"
    case "&gt;": return ">"
    default:
      let digits: Substring
      let radix: Int
      if entity.hasPrefix("&#x") {
        digits = entity.dropFirst(3).dropLast()
        radix = 16
      } else if entity.hasPrefix("&#") {
        digits = entity.dropFirst(2).dropLast()
        radix = 10
      } else {
        return nil
      }
      guard let value = UInt32(digits, radix: radix),
        let scalar = UnicodeScalar(value)
      else { return nil }
      return String(scalar)
    }
  }

  private static func validatedLinkURL(_ rawValue: String, relativeTo baseURL: URL?) -> URL? {
    guard let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      ["http", "https", "mailto"].contains(components.scheme?.lowercased() ?? ""),
      components.user == nil,
      components.password == nil
    else { return nil }
    return url
  }

  private static func validatedRemoteURL(_ rawValue: String, relativeTo baseURL: URL?) -> URL? {
    guard let url = validatedLinkURL(rawValue, relativeTo: baseURL),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return nil }
    return url
  }

  private static func archivedImageURL(
    for remoteURL: URL,
    mediaAssets: [RSSMediaAsset],
    mediaCacheDirectoryURL: URL?
  ) -> URL? {
    guard let mediaCacheDirectoryURL,
      let asset = mediaAssets.first(where: { $0.remoteURL == remoteURL })
    else { return nil }
    let root = mediaCacheDirectoryURL.standardizedFileURL
    let localURL = asset.localURL(in: root).standardizedFileURL
    guard localURL.path == root.path || localURL.path.hasPrefix(root.path + "/"),
      FileManager.default.fileExists(atPath: localURL.path)
    else { return nil }
    return localURL
  }

  private static func escapeText(_ value: String) -> String {
    replacingMatches(
      in: value,
      using: unsafeAmpersandExpression,
      with: "&amp;"
    )
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static func escapeAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
