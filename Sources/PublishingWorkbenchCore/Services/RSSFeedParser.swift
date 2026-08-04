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
    private enum FeedDialect {
      case rss2
      case atom
      case rdf
    }

    private struct ElementKey: Equatable {
      let localName: String
      let namespaceURI: String?
    }

    private enum TextTarget {
      case feedTitle
      case feedLink
      case feedIcon
      case articleTitle
      case articleID
      case articleLink
      case articleAuthor
      case articleDate
      case articleSummary(priority: Int)
      case articleContent(priority: Int)
    }

    private struct TextCapture {
      let target: TextTarget
      let owner: ElementKey
      let ownerDepth: Int
      var text = ""
    }

    private struct MarkupElement {
      let name: String
      let emitted: Bool
      let isVoid: Bool
    }

    private struct MarkupCapture {
      let target: TextTarget
      let owner: ElementKey
      let ownerDepth: Int
      let stripsStandardXHTMLWrapper: Bool
      var elements: [MarkupElement] = []
      var html = ""
    }

    private struct ArticleDraft {
      var id: String?
      var title = ""
      var link: URL?
      var author: String?
      var publishedAt: Date?
      var summaryHTML = ""
      var summaryPriority = 0
      var contentHTML = ""
      var contentPriority = 0
    }

    private static let atomNamespace = "http://www.w3.org/2005/Atom"
    private static let rss1Namespace = "http://purl.org/rss/1.0/"
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let contentNamespace = "http://purl.org/rss/1.0/modules/content/"
    private static let dcElementNamespace = "http://purl.org/dc/elements/1.1/"
    private static let dcTermsNamespace = "http://purl.org/dc/terms/"
    private static let xhtmlNamespace = "http://www.w3.org/1999/xhtml"
    private static let xhtmlAttributes: Set<String> = [
      "alt", "class", "dir", "height", "href", "id", "lang", "src", "title", "width",
    ]
    private static let htmlVoidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

    private let feedURL: URL
    private var feedTitle = ""
    private var feedSiteURL: URL?
    private var feedIconURL: URL?
    private var currentArticle: ArticleDraft?
    private var articleOwner: (key: ElementKey, depth: Int)?
    private var textCapture: TextCapture?
    private var markupCapture: MarkupCapture?
    private var articleIndex = 0
    private var rootElement: String?
    private var rootNamespaceURI: String?
    private var dialect: FeedDialect?
    private var hasRSSChannel = false
    private var elementDepth = 0
    private var elementStack: [ElementKey] = []
    private var parsedArticles: [RSSParsedArticle] = []

    var isRecognizedFeedDocument: Bool {
      switch rootElement {
      case "feed":
        return rootNamespaceURI == Self.atomNamespace
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
      let key = elementKey(
        elementName: elementName,
        namespaceURI: namespaceURI,
        qualifiedName: qName
      )
      defer { elementStack.append(key) }
      let depth = elementDepth
      elementDepth += 1

      if depth == 0 {
        rootElement = key.localName
        rootNamespaceURI = key.namespaceURI
        dialect = feedDialect(for: key)
      }

      if depth == 1, key.localName == "channel",
         (rootElement == "rss" || rootElement == "rdf"),
         isRSSCoreNamespace(key.namespaceURI) {
        hasRSSChannel = true
      }

      if var capture = markupCapture {
        appendMarkupStart(
          key: key,
          attributes: attributeDict,
          depth: depth,
          to: &capture
        )
        markupCapture = capture
        return
      }

      // Nested elements belong to the active field. They must not replace it
      // merely because they share a local name such as title or content.
      if textCapture != nil { return }

      if currentArticle == nil, isArticleElement(key) {
        currentArticle = ArticleDraft()
        articleOwner = (key, depth)
        articleIndex += 1
        return
      }

      if let plan = markupTarget(for: key, attributes: attributeDict, depth: depth) {
        markupCapture = MarkupCapture(
          target: plan.target,
          owner: key,
          ownerDepth: depth,
          stripsStandardXHTMLWrapper: plan.stripsStandardXHTMLWrapper
        )
        return
      }

      if handleAtomLink(key: key, attributes: attributeDict, depth: depth) { return }

      guard let target = textTarget(
        for: key,
        attributes: attributeDict,
        depth: depth
      ) else { return }
      textCapture = TextCapture(target: target, owner: key, ownerDepth: depth)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      if var capture = markupCapture {
        capture.html += escapeHTMLText(string)
        markupCapture = capture
      } else if var capture = textCapture {
        capture.text += string
        textCapture = capture
      }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
      let value = String(data: CDATABlock, encoding: .utf8)
        ?? String(decoding: CDATABlock, as: UTF8.self)
      if var capture = markupCapture {
        capture.html += escapeHTMLText(value)
        markupCapture = capture
      } else if var capture = textCapture {
        capture.text += value
        textCapture = capture
      }
    }

    func parser(
      _ parser: XMLParser,
      didEndElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      let depth = max(0, elementDepth - 1)
      let key = elementKey(
        elementName: elementName,
        namespaceURI: namespaceURI,
        qualifiedName: qName
      )
      defer {
        elementDepth = depth
        if !elementStack.isEmpty { elementStack.removeLast() }
      }

      if var capture = markupCapture {
        if capture.ownerDepth == depth, capture.owner == key {
          markupCapture = nil
          apply(
            target: capture.target,
            value: capture.html.trimmingCharacters(in: .whitespacesAndNewlines)
          )
        } else {
          appendMarkupEnd(to: &capture)
          markupCapture = capture
        }
        return
      }

      if let capture = textCapture {
        if capture.ownerDepth == depth, capture.owner == key {
          textCapture = nil
          apply(
            target: capture.target,
            value: capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
          )
        }
        return
      }

      if let owner = articleOwner, owner.depth == depth, owner.key == key {
        if let currentArticle {
          parsedArticles.append(makeParsedArticle(currentArticle))
        }
        currentArticle = nil
        articleOwner = nil
      }
    }

    private func feedDialect(for root: ElementKey) -> FeedDialect? {
      switch root.localName {
      case "feed" where root.namespaceURI == Self.atomNamespace:
        return .atom
      case "rss":
        return .rss2
      case "rdf" where root.namespaceURI == nil || root.namespaceURI == Self.rdfNamespace:
        return .rdf
      default:
        return nil
      }
    }

    private func isArticleElement(_ key: ElementKey) -> Bool {
      switch dialect {
      case .atom:
        return key.localName == "entry" && key.namespaceURI == Self.atomNamespace
      case .rss2:
        return key.localName == "item" && isRSSCoreNamespace(key.namespaceURI)
      case .rdf:
        return key.localName == "item" && isRSSCoreNamespace(key.namespaceURI)
      case nil:
        return false
      }
    }

    private func markupTarget(
      for key: ElementKey,
      attributes: [String: String],
      depth: Int
    ) -> (target: TextTarget, stripsStandardXHTMLWrapper: Bool)? {
      guard currentArticle != nil else { return nil }
      if dialect == .atom,
         isDirectArticleChild(at: depth),
         key.namespaceURI == Self.atomNamespace {
        let contentType = normalizedAtomContentType(in: attributes)
        if contentType == "xhtml" {
          switch key.localName {
          case "summary":
            return (.articleSummary(priority: 2), true)
          case "content" where attribute(named: "src", in: attributes) == nil:
            return (.articleContent(priority: 2), true)
          default:
            break
          }
        }
        if key.localName == "content",
           attribute(named: "src", in: attributes) == nil,
           contentType.map(isXMLMediaType) == true {
          return (.articleContent(priority: 2), false)
        }
      }
      if isDirectArticleChild(at: depth),
         key.namespaceURI == Self.xhtmlNamespace,
         key.localName == "body" {
        return (.articleContent(priority: 1), false)
      }
      return nil
    }

    private func textTarget(
      for key: ElementKey,
      attributes: [String: String],
      depth: Int
    ) -> TextTarget? {
      if currentArticle != nil {
        if dialect == .atom {
          if isAtomAuthorName(key, depth: depth) {
            return .articleAuthor
          }
          guard isDirectArticleChild(at: depth),
                key.namespaceURI == Self.atomNamespace else { return nil }
          switch key.localName {
          case "title": return .articleTitle
          case "id": return .articleID
          case "published", "updated": return .articleDate
          case "summary": return .articleSummary(priority: 2)
          case "content" where attribute(named: "src", in: attributes) == nil:
            return .articleContent(priority: 2)
          default: return nil
          }
        }
        guard isDirectArticleChild(at: depth) else { return nil }
        if key.localName == "encoded", key.namespaceURI == Self.contentNamespace {
          return .articleContent(priority: 3)
        }
        if isDCNamespace(key.namespaceURI) {
          switch key.localName {
          case "creator": return .articleAuthor
          case "date": return .articleDate
          default: return nil
          }
        }
        if isRSSCoreNamespace(key.namespaceURI) {
          switch key.localName {
          case "title": return .articleTitle
          case "guid", "id": return .articleID
          case "link": return .articleLink
          case "author": return .articleAuthor
          case "pubdate": return .articleDate
          case "description": return .articleSummary(priority: 2)
          case "summary": return .articleSummary(priority: 1)
          case "content", "encoded": return .articleContent(priority: 1)
          default: return nil
          }
        }
        return nil
      }

      if dialect == .atom, key.namespaceURI == Self.atomNamespace {
        switch key.localName {
        case "title": return .feedTitle
        case "icon", "logo": return .feedIcon
        default: return nil
        }
      }
      if isRSSCoreNamespace(key.namespaceURI) {
        switch key.localName {
        case "title": return .feedTitle
        case "link": return .feedLink
        case "icon", "logo": return .feedIcon
        default: return nil
        }
      }
      return nil
    }

    private func handleAtomLink(
      key: ElementKey,
      attributes: [String: String],
      depth: Int
    ) -> Bool {
      guard key.localName == "link", key.namespaceURI == Self.atomNamespace else {
        return false
      }
      if currentArticle != nil, !isDirectArticleChild(at: depth) {
        return true
      }
      let relation = attribute(named: "rel", in: attributes)?.lowercased()
      guard relation == nil || relation == "alternate",
            let href = attribute(named: "href", in: attributes),
            let resolved = resolveURL(href) else {
        return true
      }
      if currentArticle != nil {
        if currentArticle?.link == nil { currentArticle?.link = resolved }
      } else if feedSiteURL == nil {
        feedSiteURL = resolved
      }
      return true
    }

    private func apply(target: TextTarget, value: String) {
      guard !value.isEmpty else { return }
      switch target {
      case .feedTitle:
        if feedTitle.isEmpty { feedTitle = value }
      case .feedLink:
        if feedSiteURL == nil { feedSiteURL = resolveURL(value) }
      case .feedIcon:
        if feedIconURL == nil { feedIconURL = resolveURL(value) }
      case .articleTitle, .articleID, .articleLink, .articleAuthor, .articleDate,
        .articleSummary, .articleContent:
        guard var article = currentArticle else { return }
        switch target {
        case .articleTitle:
          if article.title.isEmpty { article.title = value }
        case .articleID:
          if article.id == nil { article.id = value }
        case .articleLink:
          if article.link == nil { article.link = resolveURL(value) }
        case .articleAuthor:
          if article.author == nil { article.author = value }
        case .articleDate:
          if article.publishedAt == nil { article.publishedAt = RSSDateParser.parse(value) }
        case let .articleSummary(priority):
          if article.summaryHTML.isEmpty || priority > article.summaryPriority {
            article.summaryHTML = value
            article.summaryPriority = priority
          }
        case let .articleContent(priority):
          if article.contentHTML.isEmpty || priority > article.contentPriority {
            article.contentHTML = value
            article.contentPriority = priority
          }
        case .feedTitle, .feedLink, .feedIcon:
          break
        }
        currentArticle = article
      }
    }

    private func appendMarkupStart(
      key: ElementKey,
      attributes: [String: String],
      depth: Int,
      to capture: inout MarkupCapture
    ) {
      let isOuterWrapper = capture.elements.isEmpty
        && capture.stripsStandardXHTMLWrapper
        && depth == capture.ownerDepth + 1
        && key.namespaceURI == Self.xhtmlNamespace
        && key.localName == "div"
      guard !isOuterWrapper else {
        capture.elements.append(MarkupElement(name: key.localName, emitted: false, isVoid: false))
        return
      }

      let isVoid = Self.htmlVoidTags.contains(key.localName)
      let attributesHTML = serializedXHTMLAttributes(attributes)
      capture.html += "<\(key.localName)\(attributesHTML)>"
      capture.elements.append(
        MarkupElement(name: key.localName, emitted: true, isVoid: isVoid)
      )
    }

    private func appendMarkupEnd(to capture: inout MarkupCapture) {
      guard let element = capture.elements.popLast() else { return }
      if element.emitted, !element.isVoid {
        capture.html += "</\(element.name)>"
      }
    }

    private func serializedXHTMLAttributes(_ attributes: [String: String]) -> String {
      attributes.keys.sorted().compactMap { rawName -> String? in
        let localName = rawName.split(separator: ":").last.map(String.init)?.lowercased()
          ?? rawName.lowercased()
        guard Self.xhtmlAttributes.contains(localName),
              let value = attributes[rawName] else { return nil }
        return " \(localName)=\"\(escapeHTMLAttribute(value))\""
      }.joined()
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

    private func elementKey(
      elementName: String,
      namespaceURI: String?,
      qualifiedName: String?
    ) -> ElementKey {
      let rawName = qualifiedName ?? elementName
      let localName = rawName.split(separator: ":").last.map(String.init)?.lowercased()
        ?? rawName.lowercased()
      return ElementKey(
        localName: localName,
        namespaceURI: namespaceURI?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      )
    }

    private func isRSSCoreNamespace(_ namespaceURI: String?) -> Bool {
      switch dialect {
      case .rss2:
        // RSS 2.0 itself has no required namespace, but some generators place
        // all core elements in a feed-specific default namespace. Preserve
        // that established compatibility without accepting extension fields.
        return namespaceURI == nil || namespaceURI == rootNamespaceURI
      case .rdf:
        return namespaceURI == nil || namespaceURI == Self.rss1Namespace
      case .atom, nil:
        return false
      }
    }

    private func isDCNamespace(_ namespaceURI: String?) -> Bool {
      namespaceURI == Self.dcElementNamespace || namespaceURI == Self.dcTermsNamespace
    }

    private func isDirectArticleChild(at depth: Int) -> Bool {
      guard let articleOwner else { return false }
      return depth == articleOwner.depth + 1
    }

    private func isAtomAuthorName(_ key: ElementKey, depth: Int) -> Bool {
      guard dialect == .atom,
            key.localName == "name",
            key.namespaceURI == Self.atomNamespace,
            let articleOwner,
            depth == articleOwner.depth + 2,
            let parent = elementStack.last else { return false }
      return parent.localName == "author" && parent.namespaceURI == Self.atomNamespace
    }

    private func normalizedAtomContentType(in attributes: [String: String]) -> String? {
      attribute(named: "type", in: attributes)?
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
        .first
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    private func isXMLMediaType(_ contentType: String) -> Bool {
      contentType == "application/xml"
        || contentType == "text/xml"
        || contentType.hasSuffix("+xml")
    }

    private func attribute(named name: String, in attributes: [String: String]) -> String? {
      attributes.first { rawName, _ in
        let localName = rawName.split(separator: ":").last.map(String.init)?.lowercased()
          ?? rawName.lowercased()
        return localName == name
      }?.value.nilIfEmpty
    }

    private func escapeHTMLText(_ value: String) -> String {
      value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeHTMLAttribute(_ value: String) -> String {
      escapeHTMLText(value)
        .replacingOccurrences(of: "\"", with: "&quot;")
    }
  }
}

private enum RSSDateParser {
  static func parse(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let iso8601 = ISO8601DateFormatter()
    if let date = iso8601.date(from: trimmed) { return date }

    return [
      "EEE, dd MMM yyyy HH:mm:ss zzz",
      "EEE, dd MMM yyyy HH:mm zzz",
      "dd MMM yyyy HH:mm:ss zzz",
    ].lazy.compactMap { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      return formatter.date(from: trimmed)
    }.first
  }
}
