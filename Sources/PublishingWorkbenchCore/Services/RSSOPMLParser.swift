import Foundation

public struct RSSOPMLSubscription: Equatable, Hashable, Sendable {
  public var title: String
  public var url: URL
  public var siteURL: URL?

  public init(title: String, url: URL, siteURL: URL? = nil) {
    self.title = title
    self.url = url
    self.siteURL = siteURL
  }
}

public enum RSSOPMLParser {
  private static let maximumDocumentSize = 5 * 1024 * 1024
  private static let maximumXMLCharacterCount = 5 * 1_024 * 1_024
  private static let maximumXMLElementDepth = 256
  private static let maximumOutlineCount = 10_000

  public static func parse(data: Data) throws -> [RSSOPMLSubscription] {
    guard !data.isEmpty else { throw RSSReaderError.invalidOPML("文件为空") }
    guard data.count <= maximumDocumentSize else {
      throw RSSReaderError.invalidOPML("文件超过 5 MB")
    }
    do {
      try UntrustedXMLParserGuard.validate(
        data: data,
        limits: UntrustedXMLParserGuard.Limits(
          maximumCharacterCount: maximumXMLCharacterCount,
          maximumElementDepth: maximumXMLElementDepth
        )
      )
    } catch let failure as UntrustedXMLParserGuard.Failure {
      switch failure {
      case .forbiddenDeclaration:
        throw RSSReaderError.invalidOPML("文件包含不安全的 DTD 或实体声明")
      case .characterLimitExceeded:
        throw RSSReaderError.invalidOPML("文件展开后的字符数超过安全上限")
      case .elementDepthExceeded:
        throw RSSReaderError.invalidOPML("文件元素嵌套深度超过安全上限")
      case .cancelled:
        throw RSSReaderError.invalidOPML("文件解析已取消")
      }
    }
    let delegate = ParserDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
      if let failure = delegate.failure { throw failure }
      throw RSSReaderError.invalidOPML(parser.parserError?.localizedDescription ?? "XML 格式不正确")
    }
    guard delegate.isValidOPMLDocument else {
      throw RSSReaderError.invalidOPML("文件不是有效的 OPML 文档")
    }
    guard !delegate.subscriptions.isEmpty else {
      throw RSSReaderError.noOPMLFeeds
    }
    return delegate.subscriptions
  }

  private final class ParserDelegate: NSObject, XMLParserDelegate {
    var subscriptions: [RSSOPMLSubscription] = []
    var failure: RSSReaderError?
    private(set) var isValidOPMLDocument = false
    private var seenURLs = Set<String>()
    private var elementStack: [String] = []
    private var bodyDepth: Int?
    private var outlineCount = 0

    func parser(
      _ parser: XMLParser,
      didStartElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?,
      attributes attributeDict: [String: String] = [:]
    ) {
      let name = normalizedName(elementName, qualifiedName: qName)
      if elementStack.isEmpty, name != "opml" {
        failure = .invalidOPML("文件根节点不是 OPML")
        parser.abortParsing()
        return
      }
      elementStack.append(name)
      if name == "outline" {
        guard outlineCount < RSSOPMLParser.maximumOutlineCount else {
          failure = .invalidOPML("OPML 条目超过 \(RSSOPMLParser.maximumOutlineCount) 条")
          parser.abortParsing()
          return
        }
        outlineCount += 1
      }
      if name == "body", elementStack.count == 2, elementStack.first == "opml" {
        bodyDepth = elementStack.count
        isValidOPMLDocument = true
      }

      guard name == "outline", bodyDepth != nil else { return }
      guard let rawFeedString = attributeDict.firstValue(
        caseInsensitive: ["xmlUrl", "xmlurl", "url"]
      ) else { return }
      let feedString = rawFeedString.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !feedString.isEmpty,
            let url = URL(string: feedString)
      else { return }
      guard !RSSSubscriptionURLPrivacy.containsUserInfo(url) else {
        failure = .invalidOPML("OPML 包含带用户名或密码的订阅地址，已拒绝导入。")
        parser.abortParsing()
        return
      }
      guard isSupported(url) else { return }
      let key = url.absoluteString
      guard seenURLs.insert(key).inserted else { return }

      let title = (
        attributeDict.firstValue(caseInsensitive: ["text", "title"])
          ?? url.host
          ?? url.absoluteString
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)

      let parsedSiteURL = attributeDict.firstValue(caseInsensitive: ["htmlUrl", "htmlurl"])
        .flatMap(URL.init(string:))
      if let parsedSiteURL, RSSSubscriptionURLPrivacy.containsUserInfo(parsedSiteURL) {
        failure = .invalidOPML("OPML 包含带用户名或密码的站点地址，已拒绝导入。")
        parser.abortParsing()
        return
      }
      let siteURL = parsedSiteURL.flatMap { isSupported($0) ? $0 : nil }
      subscriptions.append(
        RSSOPMLSubscription(
          title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
          url: url,
          siteURL: siteURL
        )
      )
    }

    func parser(
      _ parser: XMLParser,
      didEndElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      let name = normalizedName(elementName, qualifiedName: qName)
      if name == "body", bodyDepth == elementStack.count {
        bodyDepth = nil
      }
      if elementStack.last == name {
        elementStack.removeLast()
      }
    }

    private func isSupported(_ url: URL) -> Bool {
      guard let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
            !host.isEmpty
      else { return false }
      return true
    }

    private func normalizedName(_ elementName: String, qualifiedName: String?) -> String {
      let rawName = qualifiedName ?? elementName
      return rawName.split(separator: ":").last.map(String.init)?.lowercased()
        ?? rawName.lowercased()
    }
  }
}

private extension Dictionary where Key == String, Value == String {
  func firstValue(caseInsensitive keys: [String]) -> String? {
    for key in keys {
      if let value = self[key] { return value }
      if let match = first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
        return match.value
      }
    }
    return nil
  }
}
