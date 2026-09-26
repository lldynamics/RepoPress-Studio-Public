import Foundation

public struct LocalSitePreviewPageProbeResult: Sendable {
  public let statusCode: Int
  public let responseURL: URL?
  public let redirectURL: URL?
  public let responseHeaders: [String: String]

  public init(
    statusCode: Int,
    responseURL: URL?,
    redirectURL: URL? = nil,
    responseHeaders: [String: String] = [:]
  ) {
    self.statusCode = statusCode
    self.responseURL = responseURL
    self.redirectURL = redirectURL
    self.responseHeaders = responseHeaders
  }
}

/// Waits for one concrete page, not merely an occupied preview port.
///
/// Requests are intentionally restricted to numeric loopback URLs. Transport
/// redirects are not followed; only a bounded same-origin loopback redirect may be
/// followed explicitly, and readiness still requires a 2xx page response.
public struct LocalSitePreviewPageReadinessService: Sendable {
  private let probe: @Sendable (URLRequest) async throws -> LocalSitePreviewPageProbeResult
  private let pause: @Sendable (Duration) async throws -> Void

  public init() {
    probe = Self.performProbe
    pause = { duration in try await Task.sleep(for: duration) }
  }

  public init(
    probe: @escaping @Sendable (URLRequest) async throws -> LocalSitePreviewPageProbeResult
  ) {
    self.init(
      probe: probe,
      pause: { duration in try await Task.sleep(for: duration) }
    )
  }

  public init(
    probe: @escaping @Sendable (URLRequest) async throws -> LocalSitePreviewPageProbeResult,
    pause: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.probe = probe
    self.pause = pause
  }

  public func waitUntilReady(
    _ url: URL,
    maxAttempts: Int = LocalSitePreviewStartupBudget.normalMaximumReadinessAttempts,
    maximumWait: Duration? = nil
  ) async -> Bool {
    guard Self.isAllowedLoopbackURL(url) else { return false }
    let attemptCount = min(
      max(1, maxAttempts),
      LocalSitePreviewStartupBudget.maximumReadinessAttempts(for: .quartz)
    )
    let clock = ContinuousClock()
    let deadline = maximumWait.map { clock.now + $0 }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 1.5
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

    var visitedURLs: Set<URL> = [url]
    for attempt in 0..<attemptCount {
      guard
        !Task.isCancelled,
        deadline.map({ clock.now < $0 }) ?? true
      else { return false }
      do {
        let result = try await probe(request)
        guard
          !Task.isCancelled,
          deadline.map({ clock.now < $0 }) ?? true
        else { return false }
        if result.responseURL == request.url, (200...299).contains(result.statusCode) {
          return true
        }
        if result.responseURL == request.url,
          (300...399).contains(result.statusCode),
          let redirectURL = result.redirectURL,
          Self.hasSameLoopbackOrigin(redirectURL, as: url),
          visitedURLs.insert(redirectURL).inserted
        {
          request.url = redirectURL
          continue
        }
      } catch is CancellationError {
        return false
      } catch {
        // A dev server normally refuses connections while its first build is
        // still running. The bounded retry below is the expected recovery.
      }

      guard attempt + 1 < attemptCount else { break }
      let delayMilliseconds = min(1_000, 250 + attempt * 100)
      do {
        try await pause(.milliseconds(delayMilliseconds))
      } catch {
        return false
      }
    }
    return false
  }

  static func isAllowedLoopbackURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "http",
      url.host == "127.0.0.1",
      let port = url.port,
      (1...65_535).contains(port),
      url.user == nil,
      url.password == nil
    else {
      return false
    }
    return true
  }

  private static func hasSameLoopbackOrigin(_ candidate: URL, as original: URL) -> Bool {
    isAllowedLoopbackURL(candidate)
      && candidate.scheme?.lowercased() == original.scheme?.lowercased()
      && candidate.host == original.host
      && candidate.port == original.port
  }

  private static func performProbe(_ request: URLRequest) async throws
    -> LocalSitePreviewPageProbeResult
  {
    try await LocalSitePreviewHTTPMetadataProbe.perform(request)
  }
}
