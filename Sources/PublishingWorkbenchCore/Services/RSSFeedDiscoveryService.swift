import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RSSFeedDiscoveryService: Sendable {
  public static let defaultMaximumResponseByteCount = 2 * 1024 * 1024

  public let maximumResponseByteCount: Int
  public let timeoutInterval: TimeInterval

  public init(
    maximumResponseByteCount: Int = RSSFeedDiscoveryService.defaultMaximumResponseByteCount,
    timeoutInterval: TimeInterval = 20
  ) {
    self.maximumResponseByteCount = maximumResponseByteCount
    self.timeoutInterval = timeoutInterval
  }

  public func discover(from homepageURL: URL) async throws -> [URL] {
    guard let scheme = homepageURL.scheme?.lowercased(), !homepageURL.absoluteString.isEmpty else {
      throw RSSReaderError.invalidFeedURL
    }
    guard scheme == "http" || scheme == "https" else {
      throw RSSReaderError.unsupportedFeedURL
    }

    var request = URLRequest(url: homepageURL)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = timeoutInterval
    request.setValue("text/html, application/xhtml+xml;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
    request.setValue("RepoPress Studio RSS Reader", forHTTPHeaderField: "User-Agent")

    let session = CredentialSafeURLSession.make(
      timeoutIntervalForRequest: timeoutInterval,
      timeoutIntervalForResource: timeoutInterval + 10
    )
    defer { session.invalidateAndCancel() }

    do {
      let (data, response) = try await BoundedHTTPResponseLoader.data(
        for: request,
        using: session,
        maximumByteCount: maximumResponseByteCount
      )
      guard let httpResponse = response as? HTTPURLResponse else {
        throw RSSReaderError.invalidHTTPResponse
      }
      guard (200..<300).contains(httpResponse.statusCode) else {
        throw RSSReaderError.httpStatus(httpResponse.statusCode)
      }
      guard let html = String(data: data, encoding: .utf8) else {
        throw RSSReaderError.parseFailed("网页不是可识别的 UTF-8 文本")
      }
      return Self.feedURLs(in: html, relativeTo: response.url ?? homepageURL)
    } catch let error as RSSReaderError {
      throw error
    } catch {
      throw RSSReaderError.network(error.localizedDescription)
    }
  }

  public static func feedURLs(in html: String, relativeTo baseURL: URL) -> [URL] {
    var results: [URL] = []
    var seen = Set<String>()

    func append(_ value: String?) {
      guard let value else { return }
      let trimmed = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "&amp;", with: "&")
      guard !trimmed.isEmpty,
            let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
      else { return }
      var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
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
