import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RSSFeedDiscoveryService: Sendable {
  public static let defaultMaximumResponseByteCount = 2 * 1024 * 1024

  public let maximumResponseByteCount: Int
  public let timeoutInterval: TimeInterval
  public let allowsPrivateNetworkAccess: Bool

  public init(
    maximumResponseByteCount: Int = RSSFeedDiscoveryService.defaultMaximumResponseByteCount,
    timeoutInterval: TimeInterval = 20,
    allowsPrivateNetworkAccess: Bool = false
  ) {
    self.maximumResponseByteCount = maximumResponseByteCount
    self.timeoutInterval = timeoutInterval
    self.allowsPrivateNetworkAccess = allowsPrivateNetworkAccess
  }

  public func discover(from homepageURL: URL) async throws -> [URL] {
    // The network client performs DNS validation immediately before opening
    // its pinned connection; avoid a second DNS lookup here.
    let validatedHomepageURL = try RSSNetworkURLPolicy.syntacticallyValidatedURL(
      homepageURL,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
    )

    var request = URLRequest(url: validatedHomepageURL)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = timeoutInterval
    request.setValue("text/html, application/xhtml+xml;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
    request.setValue("RepoPress Studio RSS Reader", forHTTPHeaderField: "User-Agent")

    do {
      let (data, response) = try await RSSNetworkHTTPClient.data(
        for: request,
        maximumByteCount: maximumResponseByteCount,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
      )
      guard (200..<300).contains(response.statusCode) else {
        throw RSSReaderError.httpStatus(response.statusCode)
      }
      guard let html = String(data: data, encoding: .utf8) else {
        throw RSSReaderError.parseFailed("网页不是可识别的 UTF-8 文本")
      }
      return Self.feedURLs(
        in: html,
        relativeTo: response.url ?? validatedHomepageURL,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
      )
    } catch let error as RSSReaderError {
      throw error
    } catch {
      throw RSSReaderError.network(error.localizedDescription)
    }
  }

  public static func feedURLs(
    in html: String,
    relativeTo baseURL: URL,
    allowsPrivateNetworkAccess: Bool = false
  ) -> [URL] {
    var results: [URL] = []
    var seen = Set<String>()

    func append(_ value: String?) {
      guard let value else { return }
      let trimmed = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "&amp;", with: "&")
      guard !trimmed.isEmpty,
            let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
            let normalized = try? RSSNetworkURLPolicy.syntacticallyValidatedURL(
              url,
              allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
            )
      else { return }
      var components = URLComponents(url: normalized, resolvingAgainstBaseURL: true)
      components?.fragment = nil
      guard let normalized = components?.url else { return }
      guard seen.insert(normalized.absoluteString).inserted else { return }
      results.append(normalized)
    }

    let tagPattern = #"(?is)<link\b[^>]*>"#
    for match in matches(of: tagPattern, in: html) {
      let attributes = attributes(in: match)
      let rel = attributes["rel"]?.lowercased().split(whereSeparator: { $0.isWhitespace }) ?? []
      let type = attributes["type"]?.lowercased() ?? ""
      guard rel.contains("alternate"),
            type.contains("rss") || type.contains("atom") || type.contains("feed") || type == "application/xml"
      else { continue }
      append(attributes["href"])
    }

    let anchorPattern = #"(?is)<a\b[^>]*>"#
    for match in matches(of: anchorPattern, in: html) {
      let attributes = attributes(in: match)
      guard let href = attributes["href"]?.lowercased(),
            href.contains("rss") || href.contains("atom") || href.contains("feed") || href.hasSuffix(".xml")
      else { continue }
      append(attributes["href"])
    }

    return Array(results.prefix(10))
  }

  private static func matches(of pattern: String, in source: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    return expression.matches(in: source, range: range).compactMap { match in
      guard let range = Range(match.range, in: source) else { return nil }
      return String(source[range])
    }
  }

  private static func attributes(in tag: String) -> [String: String] {
    let pattern = #"(?i)([a-z_:][a-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    var values: [String: String] = [:]
    for match in expression.matches(in: tag, range: range) {
      guard let nameRange = Range(match.range(at: 1), in: tag)
      else { continue }
      let name = String(tag[nameRange]).lowercased()
      for index in 2...4 {
        if let valueRange = Range(match.range(at: index), in: tag) {
          values[name] = String(tag[valueRange])
          break
        }
      }
    }
    return values
  }
}
