import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ExternalLinkHTTPCheckState: String, Codable, Hashable, Sendable {
  case reachable
  case redirected
  case clientError
  case serverError
  case invalidURL
  case invalidResponse
  case blocked
  case networkFailure
}

public struct ExternalLinkHTTPCheckResult: Codable, Hashable, Sendable {
  public var requestedURL: URL
  public var finalURL: URL?
  public var redirectChain: [URL]
  public var state: ExternalLinkHTTPCheckState
  public var statusCode: Int?
  public var responseTimeMilliseconds: Int
  public var checkedAt: Date
  public var message: String

  public var isHealthy: Bool {
    state == .reachable || state == .redirected
  }

  public init(
    requestedURL: URL,
    finalURL: URL? = nil,
    redirectChain: [URL] = [],
    state: ExternalLinkHTTPCheckState,
    statusCode: Int? = nil,
    responseTimeMilliseconds: Int,
    checkedAt: Date,
    message: String
  ) {
    self.requestedURL = requestedURL
    self.finalURL = finalURL
    self.redirectChain = redirectChain
    self.state = state
    self.statusCode = statusCode
    self.responseTimeMilliseconds = responseTimeMilliseconds
    self.checkedAt = checkedAt
    self.message = message
  }
}

public protocol ExternalLinkHTTPTransport: Sendable {
  func data(
    for request: URLRequest,
    maximumByteCount: Int
  ) async throws -> (Data, URLResponse)
}

private final class ExternalLinkNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public struct URLSessionExternalLinkHTTPTransport: ExternalLinkHTTPTransport {
  private let session: URLSession

  public init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.httpCookieAcceptPolicy = .never
      configuration.timeoutIntervalForRequest = 15
      configuration.timeoutIntervalForResource = 20
      self.session = URLSession(
        configuration: configuration,
        delegate: ExternalLinkNoRedirectDelegate(),
        delegateQueue: nil
      )
    }
  }

  public func data(
    for request: URLRequest,
    maximumByteCount: Int
  ) async throws -> (Data, URLResponse) {
    try await BoundedHTTPResponseLoader.data(
      for: request,
      using: session,
      maximumByteCount: maximumByteCount
    )
  }
}

public enum ExternalLinkHTTPCheckError: LocalizedError, Hashable, Sendable {
  case invalidURL
  case blockedAddress(String)
  case addressResolutionFailed(String)
  case tooManyRedirects
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "只支持不含账号信息的 HTTP 或 HTTPS 外链。"
    case .blockedAddress(let host):
      return "已阻止访问本机、私网或不可公开路由的地址：\(host)。"
    case .addressResolutionFailed(let host):
      return "无法安全解析外链地址：\(host)。"
    case .tooManyRedirects:
      return "外链重定向次数超过上限。"
    case .invalidResponse:
      return "服务器没有返回有效的 HTTP 响应。"
    }
  }
}

public struct ExternalLinkHTTPCheckService: Sendable {
  static let maximumBatchCount = 200
  static let maximumRedirectCount = 5
  static let maximumResponseByteCount = 64 * 1_024

  private let transport: ExternalLinkHTTPTransport
  private let resolver: KnowledgeWebDownloadPolicy.Resolver
  private let now: @Sendable () -> Date

  public init(
    transport: ExternalLinkHTTPTransport = URLSessionExternalLinkHTTPTransport()
  ) {
    self.transport = transport
    self.resolver = KnowledgeWebDownloadPolicy.defaultResolver
    self.now = { Date() }
  }

  init(
    transport: ExternalLinkHTTPTransport,
    resolver: @escaping KnowledgeWebDownloadPolicy.Resolver,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.resolver = resolver
    self.now = now
  }

  public func check(_ url: URL) async -> ExternalLinkHTTPCheckResult {
    let startedAt = ContinuousClock.now
    let checkedAt = now()
    do {
      let received = try await performCheck(url)
      let elapsed = startedAt.duration(to: .now)
      let milliseconds = max(0, Int(elapsed.components.seconds * 1_000)
        + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
      let state: ExternalLinkHTTPCheckState
      switch received.response.statusCode {
      case 200..<400:
        state = received.redirectChain.isEmpty ? .reachable : .redirected
      case 400..<500:
        state = .clientError
      case 500..<600:
        state = .serverError
      default:
        state = .invalidResponse
      }
      return ExternalLinkHTTPCheckResult(
        requestedURL: url,
        finalURL: received.response.url,
        redirectChain: received.redirectChain,
        state: state,
        statusCode: received.response.statusCode,
        responseTimeMilliseconds: milliseconds,
        checkedAt: checkedAt,
        message: "HTTP \(received.response.statusCode)"
      )
    } catch {
      let elapsed = startedAt.duration(to: .now)
      let milliseconds = max(0, Int(elapsed.components.seconds * 1_000)
        + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
      let state: ExternalLinkHTTPCheckState
      if case ExternalLinkHTTPCheckError.invalidURL = error {
        state = .invalidURL
      } else if case ExternalLinkHTTPCheckError.blockedAddress = error {
        state = .blocked
      } else if case ExternalLinkHTTPCheckError.addressResolutionFailed = error {
        state = .blocked
      } else {
        state = .networkFailure
      }
      return ExternalLinkHTTPCheckResult(
        requestedURL: url,
        state: state,
        responseTimeMilliseconds: milliseconds,
        checkedAt: checkedAt,
        message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      )
    }
  }

  public func check(
    _ urls: [URL],
    maximumConcurrentChecks: Int = 6
  ) async -> [ExternalLinkHTTPCheckResult] {
    var uniqueURLs: [URL] = []
    var seen = Set<String>()
    for url in urls.prefix(Self.maximumBatchCount) {
      let key = url.absoluteString
      if seen.insert(key).inserted {
        uniqueURLs.append(url)
      }
    }

    let concurrency = min(12, max(1, maximumConcurrentChecks))
    var indexedResults: [(Int, ExternalLinkHTTPCheckResult)] = []
    indexedResults.reserveCapacity(uniqueURLs.count)
    for startIndex in stride(from: 0, to: uniqueURLs.count, by: concurrency) {
      let endIndex = min(startIndex + concurrency, uniqueURLs.count)
      await withTaskGroup(of: (Int, ExternalLinkHTTPCheckResult).self) { group in
        for index in startIndex..<endIndex {
          let url = uniqueURLs[index]
          group.addTask {
            (index, await check(url))
          }
        }
        for await result in group {
          indexedResults.append(result)
        }
      }
    }
    return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
  }

  private func performCheck(
    _ originalURL: URL
  ) async throws -> (response: HTTPURLResponse, redirectChain: [URL]) {
    var currentURL = originalURL
    var redirectChain: [URL] = []
    var method = "HEAD"
    var usedGetFallback = false

    for redirectCount in 0...Self.maximumRedirectCount {
      try Task.checkCancellation()
      let validatedURL = try await validatedPublicURL(currentURL)
      var request = URLRequest(url: validatedURL)
      request.httpMethod = method
      request.timeoutInterval = 15
      request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      request.setValue("RepoPress-Studio-Link-Checker/1.0", forHTTPHeaderField: "User-Agent")
      request.setValue("text/html,application/xhtml+xml,*/*;q=0.1", forHTTPHeaderField: "Accept")
      if method == "GET" {
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
      }

      let (_, response) = try await transport.data(
        for: request,
        maximumByteCount: Self.maximumResponseByteCount
      )
      guard let httpResponse = response as? HTTPURLResponse else {
        throw ExternalLinkHTTPCheckError.invalidResponse
      }

      if [301, 302, 303, 307, 308].contains(httpResponse.statusCode) {
        guard redirectCount < Self.maximumRedirectCount,
              let location = httpResponse.value(forHTTPHeaderField: "Location"),
              let destination = URL(string: location, relativeTo: validatedURL)?.absoluteURL else {
          throw ExternalLinkHTTPCheckError.tooManyRedirects
        }
        redirectChain.append(destination)
        currentURL = destination
        method = "HEAD"
        usedGetFallback = false
        continue
      }

      if !usedGetFallback && method == "HEAD" && [405, 501].contains(httpResponse.statusCode) {
        method = "GET"
        usedGetFallback = true
        continue
      }
      return (httpResponse, redirectChain)
    }
    throw ExternalLinkHTTPCheckError.tooManyRedirects
  }

  private func validatedPublicURL(_ url: URL) async throws -> URL {
    let resolver = self.resolver
    return try await Task.detached(priority: .utility) {
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host?.nilIfEmpty,
            components.user == nil,
            components.password == nil,
            let candidate = components.url else {
        throw ExternalLinkHTTPCheckError.invalidURL
      }

      let normalizedHost = host
        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
      let localHost = normalizedHost == "localhost"
        || normalizedHost.hasSuffix(".localhost")
        || normalizedHost.hasSuffix(".local")
        || normalizedHost.hasSuffix(".internal")
        || normalizedHost == "home.arpa"
        || normalizedHost.hasSuffix(".home.arpa")
      guard !localHost else {
        throw ExternalLinkHTTPCheckError.blockedAddress(host)
      }

      let addresses: [KnowledgeResolvedAddress]
      if let literal = KnowledgeResolvedAddress(presentation: normalizedHost) {
        addresses = [literal]
      } else {
        do {
          addresses = try resolver(normalizedHost)
        } catch {
          throw ExternalLinkHTTPCheckError.addressResolutionFailed(host)
        }
      }
      guard !addresses.isEmpty else {
        throw ExternalLinkHTTPCheckError.addressResolutionFailed(host)
      }
      guard addresses.allSatisfy(\.isAllowedForExternalLinkCheck) else {
        throw ExternalLinkHTTPCheckError.blockedAddress(host)
      }
      return candidate
    }.value
  }
}

private extension KnowledgeResolvedAddress {
  /// 198.18.0.0/15 is reserved for benchmarking and is also the Fake-IP range
  /// used by common macOS packet-tunnel proxies. Allowing only that special
  /// range keeps external checks functional behind those proxies while all
  /// ordinary loopback, private, link-local and documentation ranges remain
  /// blocked.
  var isAllowedForExternalLinkCheck: Bool {
    if isPubliclyRoutable { return true }
    switch self {
    case .ipv4(let bytes):
      return bytes.count == 4
        && bytes[0] == 198
        && (18...19).contains(bytes[1])
    case .ipv6(let bytes):
      guard bytes.count == 16,
            bytes.prefix(10).allSatisfy({ $0 == 0 }),
            bytes[10] == 0xff,
            bytes[11] == 0xff else {
        return false
      }
      return bytes[12] == 198 && (18...19).contains(bytes[13])
    }
  }
}
