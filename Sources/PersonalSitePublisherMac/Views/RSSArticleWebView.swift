import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import WebKit

enum RSSArticleHTMLRenderer {
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
    mediaCacheDirectoryURL: URL? = nil
  ) -> String {
    let source = article.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? article.summaryHTML
      : article.contentHTML
    return render(
      source: source,
      baseURL: article.link,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL,
      languageTag: RSSArticleLanguageResolver.languageTag(for: article)
    )
  }

  static func render(
    source: String,
    baseURL: URL?,
    allowRemoteImages: Bool,
    mediaAssets: [RSSMediaAsset] = [],
    mediaCacheDirectoryURL: URL? = nil,
    languageTag: String = "und"
  ) -> String {
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

    let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
    <!doctype html>
    <html lang="\(escapeAttribute(languageTag))">
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src https: http: file:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';">
      <style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 4px 2px 28px; color: -apple-system-label; background: transparent; font: -apple-system-body; line-height: 1.65; overflow-wrap: anywhere; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.1em 0 0.55em; }
        p, div, blockquote, pre, ul, ol, table { margin: 0.75em 0; }
        ul, ol { padding-left: 1.6em; }
        blockquote { margin-left: 0; padding: 0.1em 1em; border-left: 3px solid -apple-system-secondary-label; color: -apple-system-secondary-label; }
        pre { padding: 0.85em 1em; border-radius: 8px; background: rgba(127, 127, 127, 0.14); overflow-x: auto; white-space: pre-wrap; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid rgba(127, 127, 127, 0.35); padding: 0.35em 0.55em; text-align: left; vertical-align: top; }
        a { color: -apple-system-link; }
        img { max-width: 100%; height: auto; border-radius: 8px; }
        .remote-image-disabled { display: inline-block; padding: 0.55em 0.8em; border: 1px dashed -apple-system-secondary-label; border-radius: 7px; color: -apple-system-secondary-label; }
        mark.rss-highlight { background: color-mix(in srgb, #ffd60a 55%, transparent); color: inherit; border-radius: 3px; padding: 0 2px; }
      </style>
    </head>
    <body>\(body)</body>
    </html>
    """
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
  let onSelectionChanged: (String) -> Void
  let onNavigationError: (String) -> Void

  init(
    article: RSSArticle,
    allowRemoteImages: Bool,
    highlights: [RSSArticleHighlight],
    mediaAssets: [RSSMediaAsset] = [],
    mediaCacheDirectoryURL: URL? = nil,
    onSelectionChanged: @escaping (String) -> Void,
    onNavigationError: @escaping (String) -> Void
  ) {
    self.article = article
    self.allowRemoteImages = allowRemoteImages
    self.highlights = highlights
    self.mediaAssets = mediaAssets
    self.mediaCacheDirectoryURL = mediaCacheDirectoryURL
    self.onSelectionChanged = onSelectionChanged
    self.onNavigationError = onNavigationError
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var lastRenderToken: String?
    var pendingHighlights: [RSSArticleHighlight] = []
    let onSelectionChanged: (String) -> Void
    let onNavigationError: (String) -> Void

    init(
      onSelectionChanged: @escaping (String) -> Void,
      onNavigationError: @escaping (String) -> Void
    ) {
      self.onSelectionChanged = onSelectionChanged
      self.onNavigationError = onNavigationError
      super.init()
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == "rssSelection", let value = message.body as? String else { return }
      onSelectionChanged(value.trimmingCharacters(in: .whitespacesAndNewlines))
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
    configuration.userContentController.addUserScript(selectionScript)
    configuration.userContentController.add(context.coordinator, name: "rssSelection")
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    webView.setValue(false, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    let highlightsToken = highlights.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
    let mediaToken = mediaAssets.map(\.id).joined(separator: ",")
    let token = "\(article.id)|\(allowRemoteImages)|\(highlightsToken)|\(mediaToken)"
    context.coordinator.pendingHighlights = highlights
    guard context.coordinator.lastRenderToken != token else { return }
    context.coordinator.lastRenderToken = token
    nsView.loadHTMLString(
      RSSArticleHTMLRenderer.render(
        article: article,
        allowRemoteImages: allowRemoteImages,
        mediaAssets: mediaAssets,
        mediaCacheDirectoryURL: mediaCacheDirectoryURL
      ),
      baseURL: article.link
    )
  }
}
