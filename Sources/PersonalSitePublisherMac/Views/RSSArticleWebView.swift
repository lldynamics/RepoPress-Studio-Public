import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import WebKit

enum RSSArticleHTMLRenderer {
  private struct SanitizedBody {
    let html: String
    let hasRenderableContent: Bool
  }

  private static let allowedTags: Set<String> = [
    "a", "blockquote", "br", "code", "del", "div", "em", "h1", "h2", "h3",
    "h4", "h5", "h6", "i", "li", "ol", "p", "pre", "s", "strong", "table",
    "tbody", "td", "tfoot", "th", "thead", "tr", "u", "ul"
  ]
  private static let voidTags: Set<String> = ["br", "img"]

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
      languageTag: RSSArticleLanguageResolver.languageTag(for: article),
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
        :root { color-scheme: \(theme.cssColorScheme); }
        html, body { width: 100%; min-height: 100%; }
        body { display: block; visibility: visible; opacity: 1; margin: 0; min-height: 100vh; padding: 4px 2px 28px; color: \(theme.cssForeground) !important; background: \(theme.cssBackground) !important; font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; font-size: \(normalizedFontSize)px; line-height: \(normalizedLineSpacing); overflow-wrap: anywhere; -webkit-text-fill-color: \(theme.cssForeground); }
        #rss-article-body { display: block; visibility: visible; opacity: 1; color: \(theme.cssForeground) !important; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.1em 0 0.55em; }
        p, div, blockquote, pre, ul, ol, table { margin: 0.75em 0; }
        ul, ol { padding-left: 1.6em; }
        blockquote { margin-left: 0; padding: 0.1em 1em; border-left: 3px solid \(theme.cssSecondaryForeground); color: \(theme.cssSecondaryForeground); }
        pre { padding: 0.85em 1em; border-radius: 8px; background: rgba(127, 127, 127, 0.14); overflow-x: auto; white-space: pre-wrap; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid rgba(127, 127, 127, 0.35); padding: 0.35em 0.55em; text-align: left; vertical-align: top; }
        a { color: \(theme.cssLink); }
        img { max-width: 100%; height: auto; border-radius: 8px; }
        .remote-image-disabled { display: inline-block; padding: 0.55em 0.8em; border: 1px dashed \(theme.cssSecondaryForeground); border-radius: 7px; color: \(theme.cssSecondaryForeground); }
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
    return summary.hasRenderableContent ? summary : content
  }

  private static func sanitizedBody(
    source: String,
    baseURL: URL?,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset],
    mediaCacheDirectoryURL: URL?
  ) -> SanitizedBody {
    let withoutDangerousBlocks = source
      .replacingOccurrences(
        of: "<!--([\\s\\S]*?)-->",
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: "<(script|style|iframe|object|embed|form|svg|math|noscript|template)\\b[^>]*>[\\s\\S]*?</\\1\\s*>",
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: "<(script|style|iframe|object|embed|form|svg|math|noscript|template)\\b[^>]*/\\s*>",
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )

    let tokenExpression = try? NSRegularExpression(pattern: "(?is)<[^>]*>")
    let sourceRange = NSRange(withoutDangerousBlocks.startIndex..., in: withoutDangerousBlocks)
    var output = ""
    var cursor = withoutDangerousBlocks.startIndex

    tokenExpression?.enumerateMatches(in: withoutDangerousBlocks, range: sourceRange) { match, _, _ in
      guard let match else { return }
      let tokenRange = Range(match.range, in: withoutDangerousBlocks)!
      if cursor < tokenRange.lowerBound {
        output += escapeText(String(withoutDangerousBlocks[cursor..<tokenRange.lowerBound]))
      }
      output += sanitizeTag(
        String(withoutDangerousBlocks[tokenRange]),
        baseURL: baseURL,
        allowRemoteImages: allowRemoteImages,
        mediaAssets: mediaAssets,
        mediaCacheDirectoryURL: mediaCacheDirectoryURL
      )
      cursor = tokenRange.upperBound
    }

    if cursor < withoutDangerousBlocks.endIndex {
      output += escapeText(String(withoutDangerousBlocks[cursor...]))
    }

    let html = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let readableText = RSSHTMLTextSanitizer.plainText(from: html)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let hasImage = html.range(of: "(?is)<img\\b", options: .regularExpression) != nil
    return SanitizedBody(
      html: html,
      hasRenderableContent: !readableText.isEmpty || hasImage
    )
  }

  private static func sanitizeTag(
    _ source: String,
    baseURL: URL?,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset],
    mediaCacheDirectoryURL: URL?
  ) -> String {
    let closingPattern = try? NSRegularExpression(pattern: "(?is)^<\\s*/\\s*([a-z0-9]+)[^>]*>$")
    if let match = closingPattern?.firstMatch(
      in: source,
      range: NSRange(source.startIndex..., in: source)
    ), let nameRange = Range(match.range(at: 1), in: source) {
      let name = source[nameRange].lowercased()
      return allowedTags.contains(name) && !voidTags.contains(name) ? "</\(name)>" : ""
    }

    let openingPattern = try? NSRegularExpression(pattern: "(?is)^<\\s*([a-z0-9]+)([\\s\\S]*?)>\\s*$")
    guard let match = openingPattern?.firstMatch(
      in: source,
      range: NSRange(source.startIndex..., in: source)
    ), let nameRange = Range(match.range(at: 1), in: source),
      let attributesRange = Range(match.range(at: 2), in: source)
    else {
      return ""
    }

    let name = source[nameRange].lowercased()
    let attributes = String(source[attributesRange])
    if name == "img" {
      guard let rawURL = attribute("src", from: attributes)
        ?? attribute("data-src", from: attributes)
        ?? attribute("data-original", from: attributes),
        let imageURL = validatedRemoteURL(rawURL, relativeTo: baseURL)
      else {
        return "<span class=\"remote-image-disabled\">远程图片已关闭，可点击“加载远程图片”查看</span>"
      }
      let alt = attribute("alt", from: attributes).map(escapeAttribute) ?? ""
      if let localURL = archivedImageURL(
        for: imageURL,
        mediaAssets: mediaAssets,
        mediaCacheDirectoryURL: mediaCacheDirectoryURL
      ) {
        return "<img src=\"\(escapeAttribute(localURL.absoluteString))\" alt=\"\(alt)\" loading=\"lazy\">"
      }
      guard allowRemoteImages else {
        return "<span class=\"remote-image-disabled\">远程图片已关闭，可点击“加载远程图片”查看</span>"
      }
      return "<img src=\"\(escapeAttribute(imageURL.absoluteString))\" alt=\"\(alt)\" loading=\"lazy\" referrerpolicy=\"no-referrer\">"
    }
    guard allowedTags.contains(name) else { return "" }
    if name == "br" { return "<br>" }
    if name == "a", let rawURL = attribute("href", from: attributes),
       let linkURL = validatedLinkURL(rawURL, relativeTo: baseURL) {
      return "<a href=\"\(escapeAttribute(linkURL.absoluteString))\" rel=\"noopener noreferrer\">"
    }
    return "<\(name)>"
  }

  private static func attribute(_ name: String, from source: String) -> String? {
    let pattern = "(?is)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
    else { return nil }
    for index in 1...3 {
      if let valueRange = Range(match.range(at: index), in: source) {
        return String(source[valueRange])
      }
    }
    return nil
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
    value
      .replacingOccurrences(
        of: "&(?!(?:#\\d+|#x[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]+);)",
        with: "&amp;",
        options: .regularExpression
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
    self.onSelectionChanged = onSelectionChanged
    self.onReadingProgress = onReadingProgress
    self.onNavigationError = onNavigationError
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var lastRenderToken: String?
    var pendingHighlights: [RSSArticleHighlight] = []
    var pendingReadingProgress = 0.0
    let onSelectionChanged: (String) -> Void
    let onReadingProgress: (Double) -> Void
    let onNavigationError: (String) -> Void

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

    func applyHighlights(to webView: WKWebView) {
      for highlight in pendingHighlights {
        let text = json(highlight.text)
        let id = json(highlight.id.uuidString)
        webView.evaluateJavaScript("window.rssApplyHighlight(\(text), \(id));")
      }
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
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!node.nodeValue || node.parentElement?.closest('mark.rss-highlight')) continue;
            const start = node.nodeValue.indexOf(text);
            if (start < 0) continue;
            const range = document.createRange();
            range.setStart(node, start);
            range.setEnd(node, start + text.length);
            const mark = document.createElement('mark');
            mark.className = 'rss-highlight';
            mark.dataset.highlightId = id;
            range.surroundContents(mark);
            break;
          }
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
    let token = "\(article.id)|\(allowRemoteImages)|\(highlightsToken)|\(mediaToken)|\(fontSize)|\(lineSpacing)|\(theme.rawValue)"
    context.coordinator.pendingHighlights = highlights
    context.coordinator.pendingReadingProgress = initialReadingProgress
    guard context.coordinator.lastRenderToken != token else { return }
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
      baseURL: article.link
    )
  }
}
