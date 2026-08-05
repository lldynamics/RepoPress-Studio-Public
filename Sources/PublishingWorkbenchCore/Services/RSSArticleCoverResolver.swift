import Foundation

/// Resolves the small amount of image metadata needed by the RSS article list.
///
/// The resolver only extracts syntactically valid HTTP(S) URLs. It never
/// performs a request; callers must use the RSS network client before loading
/// an extracted URL.
public enum RSSArticleCoverResolver {
  private static let imageTagExpression = try? NSRegularExpression(
    pattern: "(?is)<(img|source)\\b[^>]*>"
  )
  private static let metaTagExpression = try? NSRegularExpression(
    pattern: "(?is)<meta\\b[^>]*>"
  )

  public static func coverURL(
    summaryHTML: String,
    contentHTML: String,
    webPageSnapshotHTML: String? = nil,
    relativeTo baseURL: URL?
  ) -> URL? {
    if let snapshot = webPageSnapshotHTML,
       let socialImage = firstSocialImageURL(in: snapshot, relativeTo: baseURL) {
      return socialImage
    }

    for html in [contentHTML, summaryHTML] where !html.isEmpty {
      if let imageURL = firstImageURL(in: html, relativeTo: baseURL) {
        return imageURL
      }
    }
    return nil
  }

  public static func firstImageURL(
    in html: String,
    relativeTo baseURL: URL?
  ) -> URL? {
    guard let expression = imageTagExpression else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    var result: URL?
    expression.enumerateMatches(in: html, range: range) { match, _, stop in
      guard result == nil,
            let match,
            let tagRange = Range(match.range, in: html) else { return }
      let tag = String(html[tagRange])
      let rawValue = attributeValue(in: tag, named: [
        "src", "data-src", "data-original", "data-lazy-src"
      ]) ?? srcsetValue(in: tag)
      guard let rawValue,
            let url = normalizedURL(rawValue, relativeTo: baseURL) else { return }
      result = url
      stop.pointee = true
    }
    return result
  }

  public static func firstSocialImageURL(
    in html: String,
    relativeTo baseURL: URL?
  ) -> URL? {
    guard let expression = metaTagExpression else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    var result: URL?
    expression.enumerateMatches(in: html, range: range) { match, _, stop in
      guard result == nil,
            let match,
            let tagRange = Range(match.range, in: html) else { return }
      let tag = String(html[tagRange])
      let property = (
        attributeValue(in: tag, named: ["property", "name"]) ?? ""
      ).lowercased()
      guard ["og:image", "og:image:url", "twitter:image", "twitter:image:src"].contains(property),
            let rawValue = attributeValue(in: tag, named: ["content"]),
            let url = normalizedURL(rawValue, relativeTo: baseURL) else { return }
      result = url
      stop.pointee = true
    }
    return result
  }

  private static func srcsetValue(in tag: String) -> String? {
    guard let value = attributeValue(in: tag, named: ["srcset", "data-srcset"]) else {
      return nil
    }
    return value
      .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
      .first?
      .split(whereSeparator: { $0.isWhitespace })
      .first
      .map(String.init)
  }

  private static func attributeValue(in tag: String, named names: [String]) -> String? {
    for name in names {
      guard let expression = try? NSRegularExpression(
        pattern: "(?is)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s>]+))"
      ) else { continue }
      let range = NSRange(tag.startIndex..., in: tag)
      guard let match = expression.firstMatch(in: tag, range: range) else { continue }
      for index in 1..<match.numberOfRanges {
        guard let valueRange = Range(match.range(at: index), in: tag) else { continue }
        let value = decodeHTMLEntities(String(tag[valueRange]))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
      }
    }
    return nil
  }

  private static func normalizedURL(_ rawValue: String, relativeTo baseURL: URL?) -> URL? {
    guard let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
          (try? RSSNetworkURLPolicy.syntacticallyValidatedURL(
            url,
            allowsPrivateNetworkAccess: true
          )) != nil else {
      return nil
    }
    return url
  }

  private static func decodeHTMLEntities(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
  }
}
