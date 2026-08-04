import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RSSFeedFetchResult: Sendable {
  public let parsedFeed: RSSParsedFeed?
  public let responseURL: URL?
  public let etag: String?
  public let lastModified: String?
  public let notModified: Bool

  public init(
    parsedFeed: RSSParsedFeed?,
    responseURL: URL?,
    etag: String?,
    lastModified: String?,
    notModified: Bool
  ) {
    self.parsedFeed = parsedFeed
    self.responseURL = responseURL
    self.etag = etag
    self.lastModified = lastModified
    self.notModified = notModified
  }
}

public struct RSSFeedClient: Sendable {
  public static let defaultMaximumResponseByteCount = 5 * 1024 * 1024

  public let maximumResponseByteCount: Int
  public let timeoutInterval: TimeInterval
  public let allowsPrivateNetworkAccess: Bool

  public init(
    maximumResponseByteCount: Int = RSSFeedClient.defaultMaximumResponseByteCount,
    timeoutInterval: TimeInterval = 30,
    allowsPrivateNetworkAccess: Bool = false
  ) {
    self.maximumResponseByteCount = maximumResponseByteCount
    self.timeoutInterval = timeoutInterval
    self.allowsPrivateNetworkAccess = allowsPrivateNetworkAccess
  }

  public func fetch(
    feedURL: URL,
    etag: String? = nil,
    lastModified: String? = nil,
    allowsPrivateNetworkAccess overridePrivateNetworkAccess: Bool? = nil
  ) async throws -> RSSFeedFetchResult {
    guard !feedURL.absoluteString.isEmpty else {
      throw RSSReaderError.issue(RSSReaderError.invalidFeedURL.asFeedIssue())
    }
    let allowsPrivateNetworkAccess = overridePrivateNetworkAccess ?? self.allowsPrivateNetworkAccess
    let validatedURL: URL
    do {
      // Resolve exactly once, immediately before the pinned connection. The
      // initial pass only rejects malformed, credential-bearing and explicit
      // local/private addresses.
      validatedURL = try RSSNetworkURLPolicy.syntacticallyValidatedURL(
        feedURL,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
      )
    } catch let error as RSSReaderError {
      throw RSSReaderError.issue(error.asFeedIssue())
    } catch {
      throw RSSReaderError.issue(RSSReaderError.invalidFeedURL.asFeedIssue())
    }

    var request = URLRequest(url: validatedURL)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = timeoutInterval
    request.setValue("application/atom+xml, application/rss+xml, application/xml, text/xml;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
    request.setValue("RepoPress Studio RSS Reader", forHTTPHeaderField: "User-Agent")
    if let etag, !etag.isEmpty {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    if let lastModified, !lastModified.isEmpty {
      request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
    }

    do {
      let (data, response) = try await RSSNetworkHTTPClient.data(
        for: request,
        maximumByteCount: maximumResponseByteCount,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
      )
      let httpResponse = response
      let responseHeaders = httpResponse.allHeaderFields
      let responseETag = responseHeaders["Etag"] as? String
        ?? responseHeaders["ETag"] as? String
      let responseLastModified = responseHeaders["Last-Modified"] as? String

      if httpResponse.statusCode == 304 {
        return RSSFeedFetchResult(
          parsedFeed: nil,
          responseURL: response.url,
          etag: responseETag ?? etag,
          lastModified: responseLastModified ?? lastModified,
          notModified: true
        )
      }
      guard (200..<300).contains(httpResponse.statusCode) else {
        let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
        let retryAt = Self.retryDate(from: retryAfter, relativeTo: Date())
        let detail = [
          "HTTP \(httpResponse.statusCode)",
          retryAfter.map { "Retry-After=\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
        throw RSSReaderError.issue(
          RSSFeedIssue.http(
            statusCode: httpResponse.statusCode,
            retryAt: retryAt,
            technicalDetail: detail
          )
        )
      }

      return RSSFeedFetchResult(
        parsedFeed: try RSSFeedParser.parse(data: data, feedURL: response.url ?? feedURL),
        responseURL: response.url,
        etag: responseETag,
        lastModified: responseLastModified,
        notModified: false
      )
    } catch let error as RSSReaderError {
      switch error {
      case .issue:
        throw error
      default:
        throw RSSReaderError.issue(error.asFeedIssue())
      }
    } catch let error as HTTPResponseLimitError {
      throw RSSReaderError.issue(
        RSSFeedIssue(
          stage: .response,
          category: .responseTooLarge,
          retryStrategy: .requiresAction,
          userMessage: "订阅内容过大，已停止读取以保护本机资源。",
          technicalDetail: error.localizedDescription
        )
      )
    } catch let error as URLError {
      throw RSSReaderError.issue(RSSFeedIssue.from(urlError: error))
    } catch is CancellationError {
      throw RSSReaderError.issue(RSSFeedIssue.cancelled())
    } catch {
      if Task.isCancelled {
        throw RSSReaderError.issue(
          RSSFeedIssue.cancelled(technicalDetail: error.localizedDescription)
        )
      }
      throw RSSReaderError.issue(RSSFeedIssue.from(error: error))
    }
  }

  static func retryDate(
    from headerValue: String?,
    relativeTo now: Date
  ) -> Date? {
    guard let headerValue else { return nil }
    let value = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if let seconds = TimeInterval(value), seconds >= 0 {
      return now.addingTimeInterval(seconds)
    }

    let formats = [
      "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
      "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
      "EEE MMM d HH':'mm':'ss yyyy",
    ]
    for format in formats {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return max(date, now)
      }
    }
    return nil
  }
}
