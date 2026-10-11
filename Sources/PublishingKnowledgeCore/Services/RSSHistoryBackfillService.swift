import Foundation
import PublishingCoreSupport

public struct RSSHistoryRobotsPolicy: Sendable {
  struct Rule: Sendable {
    let allows: Bool
    let pattern: String
  }
  var rules: [Rule] = []
  public var crawlDelay: TimeInterval = 1
  public private(set) var sitemaps: [URL] = []

  public init(text: String) {
    var groups: [([String], [Rule], TimeInterval)] = []
    var agents: [String] = []
    var currentRules: [Rule] = []
    var delay: TimeInterval = 1
    var hasDirectives = false
    for line in text.components(separatedBy: .newlines) {
      let clean = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
      let pair = clean.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard pair.count == 2 else { continue }
      let key = pair[0].lowercased()
      if key == "sitemap", pair[1].utf8.count <= 8_192,
        let url = URL(string: pair[1]), !sitemaps.contains(url), sitemaps.count < 10
      {
        sitemaps.append(url)
      }
      if key == "user-agent" {
        if hasDirectives {
          groups.append((agents, currentRules, delay))
          agents = []
          currentRules = []
          delay = 1
          hasDirectives = false
        }
        agents.append(pair[1].lowercased())
      } else if !agents.isEmpty {
        hasDirectives = true
        if key == "allow" || key == "disallow", !pair[1].isEmpty {
          currentRules.append(Rule(allows: key == "allow", pattern: pair[1]))
        } else if key == "crawl-delay", let seconds = TimeInterval(pair[1]) {
          delay = max(1, seconds)
        }
      }
    }
    groups.append((agents, currentRules, delay))
    let specific = groups.filter { $0.0.contains("repopress") }
    let applicable = specific.isEmpty ? groups.filter { $0.0.contains("*") } : specific
    rules = applicable.flatMap(\.1)
    crawlDelay = applicable.map(\.2).max() ?? 1
  }

  public func allows(_ url: URL) -> Bool {
    let path = url.path + (url.query.map { "?" + $0 } ?? "")
    let matches = rules.filter { rule in
      let anchored = rule.pattern.hasSuffix("$")
      let pattern = anchored ? String(rule.pattern.dropLast()) : rule.pattern
      let regex =
        "^"
        + pattern.components(separatedBy: "*")
        .map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*")
        + (anchored ? "$" : "")
      return path.range(of: regex, options: .regularExpression) != nil
    }
    let strongest = matches.max { lhs, rhs in
      if lhs.pattern.count == rhs.pattern.count { return !lhs.allows && rhs.allows }
      return lhs.pattern.count < rhs.pattern.count
    }
    return strongest?.allows ?? true
  }
}

public struct RSSHistoryBackfillService: Sendable {
  public typealias DownloadOperation = @Sendable (URL) async throws -> RSSArticlePageDownload
  public let limits: RSSHistoryBackfillLimits
  let downloadOperation: DownloadOperation?
  let waitOperation: @Sendable (TimeInterval) async throws -> Void

  public init(
    limits: RSSHistoryBackfillLimits = RSSHistoryBackfillLimits(),
    downloadOperation: DownloadOperation? = nil,
    waitOperation: (@Sendable (TimeInterval) async throws -> Void)? = nil
  ) {
    self.limits = limits
    self.downloadOperation = downloadOperation
    self.waitOperation = waitOperation ?? { try await Task.sleep(for: .seconds($0)) }
  }

  func robotsPolicy(origin: URL) async throws -> RSSHistoryRobotsPolicy {
    guard let robotsURL = URL(string: "/robots.txt", relativeTo: origin)?.absoluteURL else {
      throw RSSHistoryBackfillError.unavailable(CoreL10n.text("无法定位网站的公开访问规则。"))
    }
    do {
      let page = try await fetch(robotsURL, policy: nil)
      guard RSSHistoryURLIdentity.sameOrigin(page.resolvedURL, origin),
        page.data.count <= 128 * 1_024,
        let text = String(data: page.data, encoding: .utf8)
      else { throw RSSHistoryBackfillError.unavailable(CoreL10n.text("无法安全读取网站的访问规则。")) }
      let policy = RSSHistoryRobotsPolicy(text: text)
      guard policy.crawlDelay <= 30 else {
        throw RSSHistoryBackfillError.unavailable(CoreL10n.text("网站要求更长的访问间隔，当前无法自动补齐。"))
      }
      return policy
    } catch RSSReaderError.httpStatus(404) {
      return RSSHistoryRobotsPolicy(text: "")
    } catch RSSReaderError.httpStatus(410) {
      return RSSHistoryRobotsPolicy(text: "")
    }
  }

  func download(_ url: URL, origin: URL, policy: RSSHistoryRobotsPolicy) async throws
    -> RSSArticlePageDownload
  {
    try Task.checkCancellation()
    guard RSSHistoryURLIdentity.sameOrigin(url, origin), policy.allows(url) else {
      throw RSSHistoryBackfillError.unavailable(CoreL10n.text("网站访问规则不允许读取该页面。"))
    }
    let delay = max(limits.requestDelay, policy.crawlDelay)
    if delay > 0 { try await waitOperation(delay) }
    try Task.checkCancellation()
    let page = try await fetch(url, policy: policy)
    guard RSSHistoryURLIdentity.sameOrigin(page.resolvedURL, origin),
      policy.allows(page.resolvedURL), page.data.count <= 2 * 1_024 * 1_024
    else { throw RSSHistoryBackfillError.unavailable(CoreL10n.text("页面离开了所选网站或超过读取上限。")) }
    return page
  }

  private func fetch(_ url: URL, policy: RSSHistoryRobotsPolicy?) async throws
    -> RSSArticlePageDownload
  {
    if let downloadOperation { return try await downloadOperation(url) }
    let validated = try RSSNetworkURLPolicy.syntacticallyValidatedURL(url)
    var request = URLRequest(url: validated)
    request.timeoutInterval = 20
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("RepoPress", forHTTPHeaderField: "User-Agent")
    request.setValue(
      "text/html, application/xhtml+xml, application/xml, text/xml, application/atom+xml, text/plain;q=0.8",
      forHTTPHeaderField: "Accept")
    let (data, response) = try await RSSNetworkHTTPClient.data(
      for: request, maximumByteCount: 2 * 1_024 * 1_024, allowsPrivateNetworkAccess: false,
      additionalURLValidation: { target in
        guard RSSHistoryURLIdentity.sameOrigin(target, url), policy?.allows(target) != false else {
          throw RSSHistoryBackfillError.unavailable(CoreL10n.text("重定向离开了所选网站或违反其访问规则。"))
        }
      }
    )
    if response.statusCode == 404 || response.statusCode == 410 {
      throw RSSReaderError.httpStatus(response.statusCode)
    }
    guard (200..<300).contains(response.statusCode) else {
      throw RSSReaderError.issue(
        RSSFeedIssue.http(
          statusCode: response.statusCode,
          retryAt: RSSFeedClient.retryDate(
            from: response.value(forHTTPHeaderField: "Retry-After"), relativeTo: Date()
          )
        ))
    }
    let mimeType = response.mimeType?.lowercased() ?? ""
    let robotDirectives = response.value(forHTTPHeaderField: "X-Robots-Tag")?.lowercased() ?? ""
    if robotDirectives.contains("noarchive") || robotDirectives.contains("nofollow") {
      throw RSSHistoryBackfillError.unavailable(CoreL10n.text("原文页面不允许保存内容。"))
    }
    guard
      [
        "text/html", "application/xhtml+xml", "text/plain", "application/xml", "text/xml",
        "application/atom+xml",
      ].contains(mimeType)
    else {
      throw RSSHistoryBackfillError.unavailable(CoreL10n.text("页面没有返回可识别的公开网页内容。"))
    }
    return RSSArticlePageDownload(
      data: data, sourceURL: url, resolvedURL: response.url ?? url,
      mimeType: mimeType, textEncodingName: response.textEncodingName,
      etag: response.value(forHTTPHeaderField: "ETag"),
      lastModified: response.value(forHTTPHeaderField: "Last-Modified")
    )
  }
}
