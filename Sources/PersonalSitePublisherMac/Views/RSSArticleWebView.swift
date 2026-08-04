import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import WebKit

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
    pattern: "<(script|style|iframe|object|embed|form|svg|math|noscript|template)\\b[^>]*>(?:[\\s\\S]*?</\\1\\s*>|[\\s\\S]*$)",
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
    pattern: "&(?:nbsp|zwnj|zwj|zerowidthspace|#0*(?:160|8203|8204|8205|65279)|#x0*(?:a0|200b|200c|200d|feff));",
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

  static func render(
    article: RSSArticle,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset] = [],
    mediaCacheDirectoryURL: URL? = nil,
    fontSize: Double = RSSReadingComfortConfiguration.defaultFontSize,
    lineSpacing: Double = RSSReadingComfortConfiguration.defaultLineSpacing,
    theme: RSSReadingTheme = .system,
    initialReadingProgress: Double = 0
  ) -> String {
    let body = preferredSanitizedBody(
      for: article,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL
    )
    return renderDocument(
      body: body.html,
      languageTag: RSSArticleLanguageResolver.languageTag(
        for: "\(article.title) \(body.readableSample)"
      ),
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      theme: theme,
      initialReadingProgress: initialReadingProgress
    )
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
    body: String,
    languageTag: String,
    fontSize: Double,
    lineSpacing: Double,
    theme: RSSReadingTheme,
    initialReadingProgress: Double
  ) -> String {
    let normalizedFontSize = min(
      max(fontSize.isFinite ? fontSize : RSSReadingComfortConfiguration.defaultFontSize,
          RSSReadingComfortConfiguration.fontSizeRange.lowerBound),
      RSSReadingComfortConfiguration.fontSizeRange.upperBound
    )
    let normalizedLineSpacing = min(
      max(lineSpacing.isFinite ? lineSpacing : RSSReadingComfortConfiguration.defaultLineSpacing,
          RSSReadingComfortConfiguration.lineSpacingRange.lowerBound),
      RSSReadingComfortConfiguration.lineSpacingRange.upperBound
    )
    let normalizedProgress = min(max(initialReadingProgress.isFinite ? initialReadingProgress : 0, 0), 1)
    return """
    <!doctype html>
    <html lang="\(escapeAttribute(languageTag))">
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src https: http: file:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';">
      <style>
        :root { color-scheme: \(theme.cssColorScheme); --rss-font-size: \(normalizedFontSize)px; --rss-line-spacing: \(normalizedLineSpacing); --rss-background: \(theme.cssBackground); --rss-foreground: \(theme.cssForeground); --rss-secondary-foreground: \(theme.cssSecondaryForeground); --rss-link: \(theme.cssLink); }
        html, body { width: 100%; min-height: 100%; }
        body { display: block; visibility: visible; opacity: 1; margin: 0; min-height: 100vh; padding: 4px 2px 28px; color: var(--rss-foreground) !important; background: var(--rss-background) !important; font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; font-size: var(--rss-font-size); line-height: var(--rss-line-spacing); overflow-wrap: anywhere; -webkit-text-fill-color: var(--rss-foreground); }
        #rss-article-body { display: block; width: 100%; max-width: 780px; margin: 0 auto; padding: 0 24px 48px; box-sizing: border-box; visibility: visible; opacity: 1; color: var(--rss-foreground) !important; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.1em 0 0.55em; }
        p, div, article, section, blockquote, pre, ul, ol, table, figure, details { margin: 0.75em 0; }
        ul, ol { padding-left: 1.6em; }
        blockquote { margin-left: 0; padding: 0.1em 1em; border-left: 3px solid var(--rss-secondary-foreground); color: var(--rss-secondary-foreground); }
        figure { margin-left: 0; margin-right: 0; }
        figcaption, small { color: var(--rss-secondary-foreground); }
        figcaption { margin-top: 0.4em; font-size: 0.9em; }
        hr { border: 0; border-top: 1px solid rgba(127, 127, 127, 0.35); margin: 1.25em 0; }
        summary { cursor: pointer; font-weight: 600; }
        pre { padding: 0.85em 1em; border-radius: 8px; background: rgba(127, 127, 127, 0.14); overflow-x: auto; white-space: pre-wrap; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid rgba(127, 127, 127, 0.35); padding: 0.35em 0.55em; text-align: left; vertical-align: top; }
        a { color: var(--rss-link); }
        img { max-width: 100%; height: auto; border-radius: 8px; }
        .remote-image-disabled { display: inline-block; padding: 0.55em 0.8em; border: 1px dashed var(--rss-secondary-foreground); border-radius: 7px; color: var(--rss-secondary-foreground); }
        mark.rss-highlight { background: color-mix(in srgb, #ffd60a 55%, transparent); color: inherit; border-radius: 3px; padding: 0 2px; }
      </style>
    </head>
    <body data-initial-reading-progress="\(normalizedProgress)"><main id="rss-article-body">\(body)</main></body>
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
      cjkCharacters += visibleText.unicodeScalars.filter { scalar in
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

    tagTokenExpression?.enumerateMatches(in: withoutDangerousBlocks, range: sourceRange) { match, _, _ in
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
      let html = allowedTags.contains(name) && !voidTags.contains(name)
        ? "</\(outputTagName(for: name))>"
        : ""
      return SanitizedTag(html: html, hasRenderableContent: false)
    }

    guard let match = openingTagExpression?.firstMatch(
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
      guard let rawURL = attributes["src"]
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
          html: "<img src=\"\(escapeAttribute(localURL.absoluteString))\" alt=\"\(alt)\" loading=\"lazy\">",
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
        html: "<img src=\"\(escapeAttribute(imageURL.absoluteString))\" alt=\"\(alt)\" loading=\"lazy\" referrerpolicy=\"no-referrer\">",
        hasRenderableContent: true
      )
    }
    guard allowedTags.contains(name) else { return .empty }
    if name == "br" || name == "hr" {
      return SanitizedTag(html: "<\(name)>", hasRenderableContent: false)
    }
    if name == "a", let rawURL = attributes["href"],
       let linkURL = validatedLinkURL(rawURL, relativeTo: baseURL) {
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
            source[cursor].isWhitespace || source[cursor] == "/" {
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
              !source[cursor].isWhitespace, source[cursor] != ">" {
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
            let scalar = UnicodeScalar(value) else { return nil }
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

struct RSSArticleWebView: NSViewRepresentable {
  let article: RSSArticle
  let allowRemoteImages: Bool
  let highlights: [RSSArticleHighlight]
  let mediaAssets: [RSSMediaAsset]
  let mediaCacheDirectoryURL: URL?
  let fontSize: Double
  let lineSpacing: Double
  let theme: RSSReadingTheme
  let initialReadingProgress: Double
  let renderRevision: String
  let onSelectionChanged: (String) -> Void
  let onReadingProgress: (Double) -> Void
  let onNavigationError: (String) -> Void

  init(
    article: RSSArticle,
    allowRemoteImages: Bool,
    highlights: [RSSArticleHighlight],
    mediaAssets: [RSSMediaAsset] = [],
    mediaCacheDirectoryURL: URL? = nil,
    fontSize: Double = RSSReadingComfortConfiguration.defaultFontSize,
    lineSpacing: Double = RSSReadingComfortConfiguration.defaultLineSpacing,
    theme: RSSReadingTheme = .system,
    initialReadingProgress: Double = 0,
    renderRevision: String,
    onSelectionChanged: @escaping (String) -> Void,
    onReadingProgress: @escaping (Double) -> Void = { _ in },
    onNavigationError: @escaping (String) -> Void
  ) {
    self.article = article
    self.allowRemoteImages = allowRemoteImages
    self.highlights = highlights
    self.mediaAssets = mediaAssets
    self.mediaCacheDirectoryURL = mediaCacheDirectoryURL
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.theme = theme
    self.initialReadingProgress = initialReadingProgress
    self.renderRevision = renderRevision
    self.onSelectionChanged = onSelectionChanged
    self.onReadingProgress = onReadingProgress
    self.onNavigationError = onNavigationError
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var lastRenderToken: String?
    var pendingHighlights: [RSSArticleHighlight] = []
    var pendingReadingProgress = 0.0
    var pendingFontSize = RSSReadingComfortConfiguration.defaultFontSize
    var pendingLineSpacing = RSSReadingComfortConfiguration.defaultLineSpacing
    var pendingTheme = RSSReadingTheme.system
    var onSelectionChanged: (String) -> Void
    var onReadingProgress: (Double) -> Void
    var onNavigationError: (String) -> Void

    init(
      onSelectionChanged: @escaping (String) -> Void,
      onReadingProgress: @escaping (Double) -> Void,
      onNavigationError: @escaping (String) -> Void
    ) {
      self.onSelectionChanged = onSelectionChanged
      self.onReadingProgress = onReadingProgress
      self.onNavigationError = onNavigationError
      super.init()
    }

    func updateCallbacks(
      onSelectionChanged: @escaping (String) -> Void,
      onReadingProgress: @escaping (Double) -> Void,
      onNavigationError: @escaping (String) -> Void
    ) {
      self.onSelectionChanged = onSelectionChanged
      self.onReadingProgress = onReadingProgress
      self.onNavigationError = onNavigationError
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      if message.name == "rssSelection", let value = message.body as? String {
        onSelectionChanged(value.trimmingCharacters(in: .whitespacesAndNewlines))
      } else if message.name == "rssProgress", let value = message.body as? NSNumber {
        onReadingProgress(min(max(value.doubleValue, 0), 1))
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let destination = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if destination.scheme == "about" {
        decisionHandler(.allow)
        return
      }
      guard navigationAction.navigationType == .linkActivated else {
        decisionHandler(.cancel)
        return
      }
      if destination.scheme?.lowercased() == "mailto" {
        if !NSWorkspace.shared.open(destination) {
          onNavigationError("无法打开邮件链接。")
        }
      } else {
        _ = ExternalURLOpener.open(destination, report: onNavigationError)
      }
      decisionHandler(.cancel)
    }

    func webView(
      _ webView: WKWebView,
      didFinish navigation: WKNavigation!
    ) {
      applyReadingPreferences(to: webView)
      applyHighlights(to: webView)
      let progress = min(max(pendingReadingProgress, 0), 1)
      webView.evaluateJavaScript(
        "window.rssApplyReadingProgress && window.rssApplyReadingProgress(\(progress));"
      )
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      onNavigationError(error.localizedDescription)
    }

    func applyReadingPreferences(to webView: WKWebView) {
      let script = """
      window.rssApplyReadingPreferences && window.rssApplyReadingPreferences(
        \(pendingFontSize),
        \(pendingLineSpacing),
        \(json(pendingTheme.cssBackground)),
        \(json(pendingTheme.cssForeground)),
        \(json(pendingTheme.cssSecondaryForeground)),
        \(json(pendingTheme.cssLink)),
        \(json(pendingTheme.cssColorScheme))
      );
      """
      webView.evaluateJavaScript(script)
    }

    func applyHighlights(to webView: WKWebView) {
      for highlight in pendingHighlights.sorted(by: Self.highlightRestoreOrder) {
        let text = json(highlight.text)
        let id = json(highlight.id.uuidString)
        webView.evaluateJavaScript("window.rssApplyHighlight(\(text), \(id));")
      }
    }

    private static func highlightRestoreOrder(
      _ lhs: RSSArticleHighlight,
      _ rhs: RSSArticleHighlight
    ) -> Bool {
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }

    private func json(_ value: String) -> String {
      guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
            let string = String(data: data, encoding: .utf8)
      else { return "\"\"" }
      return string
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onSelectionChanged: onSelectionChanged,
      onReadingProgress: onReadingProgress,
      onNavigationError: onNavigationError
    )
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let selectionScript = WKUserScript(
      source: """
      (() => {
        const report = () => {
          const value = (window.getSelection()?.toString() || '').trim();
          window.webkit.messageHandlers.rssSelection.postMessage(value);
        };
        document.addEventListener('selectionchange', report);
        document.addEventListener('mouseup', report);
        window.rssApplyHighlight = (text, id) => {
          if (!text || !id) return;
          const root = document.getElementById('rss-article-body') || document.body;
          if ([...root.querySelectorAll('mark.rss-highlight')].some(mark => mark.dataset.highlightId === id)) {
            return;
          }
          const normalizedNeedle = String(text).replace(/\\s+/g, ' ').trim();
          if (!normalizedNeedle) return;

          const blockSelector = 'address,article,aside,blockquote,div,dl,fieldset,figcaption,figure,footer,form,h1,h2,h3,h4,h5,h6,header,li,main,nav,ol,p,pre,section,table,td,th,ul';
          const blockElement = node => node.parentElement?.closest(blockSelector) || null;
          const characters = [];
          const positions = [];
          let previousBlock = null;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!node.nodeValue || node.parentElement?.closest('mark.rss-highlight,script,style,noscript')) {
              continue;
            }
            const currentBlock = blockElement(node);
            if (
              previousBlock &&
              currentBlock &&
              previousBlock !== currentBlock &&
              characters.length > 0 &&
              characters[characters.length - 1] !== ' '
            ) {
              characters.push(' ');
              positions.push({ node, offset: 0 });
            }
            for (let offset = 0; offset < node.nodeValue.length; offset += 1) {
              const character = node.nodeValue[offset];
              if (/\\s/.test(character)) {
                if (characters.length > 0 && characters[characters.length - 1] !== ' ') {
                  characters.push(' ');
                  positions.push({ node, offset });
                }
              } else {
                characters.push(character);
                positions.push({ node, offset });
              }
            }
            previousBlock = currentBlock;
          }
          while (characters[0] === ' ') {
            characters.shift();
            positions.shift();
          }
          while (characters[characters.length - 1] === ' ') {
            characters.pop();
            positions.pop();
          }

          const normalizedText = characters.join('');
          const matchStart = normalizedText.indexOf(normalizedNeedle);
          if (matchStart < 0) return;
          const startPosition = positions[matchStart];
          const endPosition = positions[matchStart + normalizedNeedle.length - 1];
          if (!startPosition || !endPosition) return;

          const range = document.createRange();
          range.setStart(startPosition.node, startPosition.offset);
          range.setEnd(endPosition.node, endPosition.offset + 1);
          const mark = document.createElement('mark');
          mark.className = 'rss-highlight';
          mark.dataset.highlightId = id;
          mark.appendChild(range.extractContents());
          range.insertNode(mark);
        };
      })();
      """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    let readingPreferencesScript = WKUserScript(
      source: """
      (() => {
        window.rssApplyReadingPreferences = (
          fontSize,
          lineSpacing,
          background,
          foreground,
          secondaryForeground,
          link,
          colorScheme
        ) => {
          const root = document.documentElement;
          const normalizedFontSize = Math.min(24, Math.max(13, Number(fontSize) || 17));
          const normalizedLineSpacing = Math.min(2.10, Math.max(1.35, Number(lineSpacing) || 1.65));
          root.style.setProperty('--rss-font-size', String(normalizedFontSize) + 'px');
          root.style.setProperty('--rss-line-spacing', String(normalizedLineSpacing));
          root.style.setProperty('--rss-background', String(background || 'transparent'));
          root.style.setProperty('--rss-foreground', String(foreground || '-apple-system-label'));
          root.style.setProperty('--rss-secondary-foreground', String(secondaryForeground || '-apple-system-secondary-label'));
          root.style.setProperty('--rss-link', String(link || '-apple-system-link'));
          root.style.colorScheme = String(colorScheme || 'light dark');
        };
      })();
      """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    let progressScript = WKUserScript(
      source: """
      (() => {
        const report = () => {
          const documentHeight = Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0);
          const maximum = Math.max(0, documentHeight - window.innerHeight);
          const progress = maximum > 0 ? window.scrollY / maximum : 0;
          window.webkit.messageHandlers.rssProgress.postMessage(progress);
        };
        window.rssApplyReadingProgress = (value) => {
          const documentHeight = Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0);
          const maximum = Math.max(0, documentHeight - window.innerHeight);
          window.scrollTo(0, maximum * Math.min(1, Math.max(0, Number(value) || 0)));
          report();
        };
        window.addEventListener('scroll', report, { passive: true });
        window.addEventListener('resize', report);
        report();
      })();
      """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    configuration.userContentController.addUserScript(selectionScript)
    configuration.userContentController.addUserScript(readingPreferencesScript)
    configuration.userContentController.addUserScript(progressScript)
    configuration.userContentController.add(context.coordinator, name: "rssSelection")
    configuration.userContentController.add(context.coordinator, name: "rssProgress")
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    webView.setValue(true, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    let highlightsToken = highlights.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
    let mediaToken = mediaAssets.map(\.id).joined(separator: ",")
    context.coordinator.updateCallbacks(
      onSelectionChanged: onSelectionChanged,
      onReadingProgress: onReadingProgress,
      onNavigationError: onNavigationError
    )
    context.coordinator.pendingHighlights = highlights
    context.coordinator.pendingReadingProgress = initialReadingProgress
    context.coordinator.pendingFontSize = fontSize
    context.coordinator.pendingLineSpacing = lineSpacing
    context.coordinator.pendingTheme = theme
    let token = "\(article.id)|\(renderRevision)|\(allowRemoteImages)|\(highlightsToken)|\(mediaToken)"
    guard context.coordinator.lastRenderToken != token else {
      context.coordinator.applyReadingPreferences(to: nsView)
      return
    }
    context.coordinator.lastRenderToken = token
    nsView.loadHTMLString(
      RSSArticleHTMLRenderer.render(
        article: article,
        allowRemoteImages: allowRemoteImages,
        mediaAssets: mediaAssets,
        mediaCacheDirectoryURL: mediaCacheDirectoryURL,
        fontSize: fontSize,
        lineSpacing: lineSpacing,
        theme: theme,
        initialReadingProgress: initialReadingProgress
      ),
      // The renderer has already resolved permitted relative links and image URLs.
      // Keeping this document on about:blank prevents the navigation delegate from
      // mistaking the locally rendered article for an external page navigation.
      baseURL: nil
    )
  }
}
