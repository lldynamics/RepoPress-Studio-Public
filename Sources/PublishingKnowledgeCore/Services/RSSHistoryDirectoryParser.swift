import Foundation
import PublishingCoreSupport

public struct RSSHistoryDirectoryPage: Sendable {
  public let articles: [RSSHistoryBackfillCandidate]
  public let nextPages: [URL]
  public let canonicalURL: URL?
  public let forbidsArchiving: Bool
  public let articleTitle: String?
}

/// Discovers only publisher-labelled article links, never every hyperlink.
/// There is deliberately no guessing of /page/N, API, sitemap or feed paths.
public enum RSSHistoryDirectoryParser {
  public static func parse(data: Data, responseURL: URL, origin: URL) throws
    -> RSSHistoryDirectoryPage
  {
    guard data.count <= 2 * 1_024 * 1_024,
      let html = String(data: data, encoding: .utf8),
      !html.localizedCaseInsensitiveContains("<!ENTITY")
    else { throw RSSHistoryBackfillError.unavailable(CoreL10n.text("目录内容无法安全识别。")) }
    let document = try XMLDocument(
      xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
    )
    let nodes = try document.nodes(forXPath: "//a[@href] | //link[@href] | //meta[@name]")
    guard nodes.count <= 20_000 else {
      throw RSSHistoryBackfillError.unavailable(CoreL10n.text("目录链接过多，已停止发现历史文章。"))
    }
    let articleClasses: Set<String> = [
      "archive-item-link", "archive-article-title", "post-link",
    ]
    var articles: [RSSHistoryBackfillCandidate] = []
    var nextPages: [URL] = []
    var canonicalURL: URL?
    var seen = Set<String>()
    var forbidsArchiving = false
    for case let element as XMLElement in nodes {
      try Task.checkCancellation()
      let rel = tokens(element.attribute(forName: "rel")?.stringValue)
      if element.name?.lowercased() == "meta" {
        let name = element.attribute(forName: "name")?.stringValue?.lowercased()
        if name == "robots" || name == "repopress" {
          let directives = tokens(element.attribute(forName: "content")?.stringValue)
          forbidsArchiving =
            forbidsArchiving || !directives.isDisjoint(with: ["none", "nofollow", "noarchive"])
        }
        continue
      }
      guard let href = element.attribute(forName: "href")?.stringValue,
        href.utf8.count <= 8_192,
        let url = URL(string: href, relativeTo: responseURL)?.absoluteURL,
        RSSHistoryURLIdentity.sameOrigin(url, origin),
        url.user == nil, url.password == nil,
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
      else { continue }
      if rel.contains("canonical"), element.name?.lowercased() == "link" {
        canonicalURL = url
      }
      if rel.contains("next"), !nextPages.contains(url) { nextPages.append(url) }
      guard element.name?.lowercased() == "a" else { continue }
      let classes = tokens(element.attribute(forName: "class")?.stringValue)
      guard
        rel.contains("bookmark") || !classes.isDisjoint(with: articleClasses)
          || isPublishedArticleLink(element)
      else { continue }
      let title = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, seen.insert(RSSHistoryURLIdentity.key(url)).inserted else { continue }
      articles.append(RSSHistoryBackfillCandidate(url: url, title: String(title.prefix(500))))
    }
    if forbidsArchiving {
      articles = []
      nextPages = []
    }
    return RSSHistoryDirectoryPage(
      articles: try preferredTitles(articles, in: document, responseURL: responseURL),
      nextPages: nextPages, canonicalURL: canonicalURL,
      forbidsArchiving: forbidsArchiving,
      articleTitle: try document.nodes(forXPath: "//article//h1 | //main//h1 | //title")
        .first?.stringValue.map {
          String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        }
    )
  }

  private static func isPublishedArticleLink(_ element: XMLElement) -> Bool {
    var parent = element.parent
    var inListItem = false
    for _ in 0..<12 {
      guard let node = parent as? XMLElement else { return false }
      let classes = tokens(node.attribute(forName: "class")?.stringValue)
      if ["h1", "h2", "h3"].contains(node.name?.lowercased() ?? ""),
        !classes.isDisjoint(with: ["post-title", "entry-title"])
      {
        return true
      }
      if node.name?.lowercased() == "li" { inListItem = true }
      // Hugo/XMin's archive labels the parent, not each individual anchor.
      if inListItem, classes.contains("archive"),
        classes.contains("main") || node.name?.lowercased() == "main"
      {
        return true
      }
      parent = node.parent
    }
    return false
  }

  /// Blogger bookmark links are dates; the sibling post-title carries the title.
  private static func preferredTitles(
    _ articles: [RSSHistoryBackfillCandidate], in document: XMLDocument, responseURL: URL
  ) throws -> [RSSHistoryBackfillCandidate] {
    let headings = try document.nodes(forXPath: "//h1/a[@href] | //h2/a[@href] | //h3/a[@href]")
    var titles: [String: String] = [:]
    for case let heading as XMLElement in headings where isPublishedArticleLink(heading) {
      guard let href = heading.attribute(forName: "href")?.stringValue,
        let url = URL(string: href, relativeTo: responseURL)?.absoluteURL,
        let text = heading.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else { continue }
      titles[RSSHistoryURLIdentity.key(url)] = String(text.prefix(500))
    }
    return articles.map {
      RSSHistoryBackfillCandidate(
        url: $0.url, title: titles[RSSHistoryURLIdentity.key($0.url)] ?? $0.title)
    }
  }

  private static func tokens(_ value: String?) -> Set<String> {
    Set((value ?? "").lowercased().split { $0.isWhitespace || $0 == "," }.map(String.init))
  }
}
