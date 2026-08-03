import Foundation

public enum RSSFeedParser {
  public static func parse(data: Data, feedURL: URL) throws -> RSSParsedFeed {
    guard !data.isEmpty else {
      throw RSSReaderError.parseFailed("响应为空")
    }

    let delegate = Delegate(feedURL: feedURL)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
      throw RSSReaderError.parseFailed(
        parser.parserError?.localizedDescription ?? "XML 文档格式不正确"
      )
    }

    guard delegate.isRecognizedFeedDocument else {
      throw RSSReaderError.issue(
        RSSFeedIssue(
          stage: .parsing,
          category: .invalidContent,
          retryStrategy: .requiresAction,
          userMessage: "订阅内容不是可识别的 RSS 或 Atom。",
          technicalDetail: "XML 根结构不是 rss/channel 或带 Atom 命名空间的 feed"
        )
      )
    }

    // A syntactically valid feed may legitimately have no entries yet. Treat it
    // as a successful subscription so callers can keep it and receive future
    // articles instead of putting it into a permanent error/backoff state.
    return delegate.result
  }

  private final class Delegate: NSObject, XMLParserDelegate {
    private struct ArticleDraft {
      var id: String?
      var title = ""
      var link: URL?
      var author: String?
      var publishedAt: Date?
      var summaryHTML = ""
      var contentHTML = ""
    }

    private let feedURL: URL
    private var feedTitle = ""
    private var feedSiteURL: URL?
    private var feedIconURL: URL?
    private var currentArticle: ArticleDraft?
    private var currentElement: String?
    private var textBuffer = ""
    private var articleIndex = 0
    private var rootElement: String?
    private var rootNamespaceURI: String?
    private var hasRSSChannel = false
    private var elementDepth = 0

    var isRecognizedFeedDocument: Bool {
      switch rootElement {
      case "feed":
        return rootNamespaceURI == "http://www.w3.org/2005/Atom"
      case "rss", "rdf":
        return hasRSSChannel
      default:
        return false
      }
    }

    var result: RSSParsedFeed {
      RSSParsedFeed(
        title: feedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
        siteURL: feedSiteURL,
        iconURL: feedIconURL,
        articles: parsedArticles
      )
    }

    private var parsedArticles: [RSSParsedArticle] = []

    init(feedURL: URL) {
      self.feedURL = feedURL
    }

    func parser(
      _ parser: XMLParser,
      didStartElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?,
      attributes attributeDict: [String: String] = [:]
    ) {
      let name = normalizedName(elementName, qualifiedName: qName)
      let depth = elementDepth
      elementDepth += 1
      if depth == 0 {
        rootElement = name
        rootNamespaceURI = namespaceURI
      }
      if depth == 1, name == "channel", rootElement == "rss" || rootElement == "rdf" {
        hasRSSChannel = true
      }
      if name == "item" || name == "entry" {
        currentArticle = ArticleDraft()
        articleIndex += 1
        currentElement = nil
        textBuffer = ""
        return
      }

      if name == "link", let href = attributeDict["href"], !href.isEmpty {
        let relation = attributeDict["rel"]?.lowercased()
        if relation == nil || relation == "alternate" {
          let resolved = resolveURL(href)
          if currentArticle != nil {
            currentArticle?.link = resolved
          } else {
            feedSiteURL = resolved
          }
        }
      }

      if name == "icon", currentArticle == nil {
        currentElement = name
        textBuffer = ""
        return
      }

      guard isTextElement(name) else { return }
      currentElement = name
      textBuffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      guard currentElement != nil else { return }
      textBuffer.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
      guard currentElement != nil else { return }
      textBuffer.append(
        String(data: CDATABlock, encoding: .utf8)
          ?? String(decoding: CDATABlock, as: UTF8.self)
      )
    }

    func parser(
      _ parser: XMLParser,
      didEndElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      defer { elementDepth = max(0, elementDepth - 1) }
      let name = normalizedName(elementName, qualifiedName: qName)
      if name == "item" || name == "entry" {
        if let currentArticle {
          parsedArticles.append(makeParsedArticle(currentArticle))
        }
        self.currentArticle = nil
        currentElement = nil
        textBuffer = ""
        return
      }

      guard currentElement == name else { return }
      let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
      if var article = currentArticle {
        apply(value: value, to: &article, element: name)
        currentArticle = article
      } else {
        apply(value: value, toFeedElement: name)
      }
      currentElement = nil
      textBuffer = ""
    }

    private func apply(value: String, to article: inout ArticleDraft, element: String) {
      switch element {
      case "title":
        article.title = value
      case "guid", "id":
        article.id = value.nilIfEmpty
      case "link":
        if article.link == nil { article.link = resolveURL(value) }
      case "author", "creator":
        article.author = value.nilIfEmpty
      case "pubdate", "published", "updated", "date":
        article.publishedAt = RSSDateParser.parse(value)
      case "description", "summary":
        article.summaryHTML = value
      case "content", "encoded":
        article.contentHTML = value
      default:
        break
      }
    }

    private func apply(value: String, toFeedElement element: String) {
      switch element {
      case "title":
        if feedTitle.isEmpty { feedTitle = value }
      case "link":
        if feedSiteURL == nil { feedSiteURL = resolveURL(value) }
      case "icon", "logo":
        feedIconURL = resolveURL(value)
      default:
        break
      }
    }

    private func makeParsedArticle(_ draft: ArticleDraft) -> RSSParsedArticle {
      let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let fallback = draft.link?.absoluteString
        ?? "\(feedURL.absoluteString)#\(articleIndex)"
      return RSSParsedArticle(
        id: draft.id ?? fallback,
        title: title.isEmpty ? "无标题文章" : title,
        link: draft.link,
        author: draft.author,
        publishedAt: draft.publishedAt,
        summaryHTML: draft.summaryHTML,
        contentHTML: draft.contentHTML
      )
    }

    private func resolveURL(_ value: String) -> URL? {
      guard !value.isEmpty else { return nil }
      guard let url = URL(string: value, relativeTo: feedURL)?.absoluteURL,
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https" else {
        return nil
      }
      return url
    }

    private func isTextElement(_ name: String) -> Bool {
      switch name {
      case "title", "guid", "id", "link", "author", "creator", "pubdate", "published",
        "updated", "date", "description", "summary", "content", "encoded", "icon", "logo":
        return true
      default:
        return false
      }
    }

    private func normalizedName(_ elementName: String, qualifiedName: String?) -> String {
      let rawName = qualifiedName ?? elementName
      return rawName.split(separator: ":").last.map(String.init)?.lowercased() ?? rawName.lowercased()
    }
  }
}

private enum RSSDateParser {
  private static let iso8601 = ISO8601DateFormatter()
  private static let rfc822: [DateFormatter] = {
    [
      "EEE, dd MMM yyyy HH:mm:ss zzz",
      "EEE, dd MMM yyyy HH:mm zzz",
      "dd MMM yyyy HH:mm:ss zzz",
    ].map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      return formatter
    }
  }()

  static func parse(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let date = iso8601.date(from: trimmed) { return date }
    return rfc822.lazy.compactMap { $0.date(from: trimmed) }.first
  }
}
