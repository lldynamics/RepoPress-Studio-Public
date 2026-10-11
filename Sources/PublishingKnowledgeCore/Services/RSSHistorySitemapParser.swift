import Foundation
import PublishingCoreSupport

/// Reads published sitemap locations; it never invents an index or API URL.
enum RSSHistorySitemapParser {
  static func parse(data: Data, responseURL: URL, directoryURL: URL) throws
    -> RSSHistoryDirectoryPage
  {
    guard data.count <= 2 * 1_024 * 1_024 else {
      throw RSSHistoryBackfillError.unavailable(CoreL10n.text("目录内容无法安全识别。"))
    }
    try UntrustedXMLParserGuard.validate(
      data: data,
      limits: .init(maximumCharacterCount: 2 * 1_024 * 1_024, maximumElementDepth: 64))
    let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    guard let root = document.rootElement(),
      ["urlset", "sitemapindex"].contains(root.localName ?? ""),
      root.uri == "http://www.sitemaps.org/schemas/sitemap/0.9"
    else {
      throw RSSHistoryBackfillError.unavailable(CoreL10n.text("目录内容无法安全识别。"))
    }
    let isIndex = root.localName == "sitemapindex"
    let records = root.children?.compactMap { $0 as? XMLElement } ?? []
    guard records.count <= 20_000 else {
      throw RSSHistoryBackfillError.unavailable(CoreL10n.text("目录链接过多，已停止发现历史文章。"))
    }
    var articles: [RSSHistoryBackfillCandidate] = []
    var nextPages: [URL] = []
    var seen = Set<String>()
    for record in records {
      try Task.checkCancellation()
      guard record.localName == (isIndex ? "sitemap" : "url"),
        let text = record.children?.first(where: { $0.localName == "loc" })?.stringValue?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        text.utf8.count <= 8_192,
        let url = URL(string: text),
        RSSHistoryURLIdentity.sameOrigin(url, directoryURL), url.user == nil, url.password == nil,
        seen.insert(RSSHistoryURLIdentity.key(url)).inserted
      else { continue }
      if isIndex {
        nextPages.append(url)
      } else if isWithinDirectory(url, directoryURL),
        RSSHistoryURLIdentity.key(url) != RSSHistoryURLIdentity.key(directoryURL)
      {
        // The article page supplies its title after extraction, not the URL index.
        articles.append(RSSHistoryBackfillCandidate(url: url, title: ""))
      }
    }
    return RSSHistoryDirectoryPage(
      articles: articles, nextPages: nextPages, canonicalURL: nil,
      forbidsArchiving: false, articleTitle: nil)
  }

  private static func isWithinDirectory(_ url: URL, _ directory: URL) -> Bool {
    let path = directory.path
    let prefix = path.hasSuffix("/") ? path : path + "/"
    return path.isEmpty || path == "/" || url.path.hasPrefix(prefix)
  }
}
