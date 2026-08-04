import Foundation

public enum RSSOPMLExportPrivacyAction: Equatable, Sendable {
  /// Keeps credential-like query values unchanged for compatibility with existing exports.
  case preserve
  /// Replaces credential-like query values while retaining the subscription.
  case redactCredentialQueryValues
  /// Omits a subscription when either its feed URL or site URL has credential-like query names.
  case excludeSubscriptionsWithCredentialQuery
}

public struct RSSOPMLExportResult: Equatable, Sendable {
  public let data: Data
  public let riskReport: RSSSubscriptionURLPrivacyReport
  public let exportedSubscriptionCount: Int
  public let excludedSubscriptionCount: Int

  public init(
    data: Data,
    riskReport: RSSSubscriptionURLPrivacyReport,
    exportedSubscriptionCount: Int,
    excludedSubscriptionCount: Int
  ) {
    self.data = data
    self.riskReport = riskReport
    self.exportedSubscriptionCount = exportedSubscriptionCount
    self.excludedSubscriptionCount = excludedSubscriptionCount
  }
}

/// Serializes the subscriptions in the reader to a flat OPML 2.0 document.
///
/// OPML intentionally contains only subscription metadata. Article caches and
/// reading state never leave the app. Subscription URLs can themselves contain
/// credential-like query values, so callers should scan and explicitly choose
/// redaction or exclusion before user-facing export.
public enum RSSOPMLWriter {
  @available(*, deprecated, message: "Choose an explicit RSSOPMLExportPrivacyAction for export UI.")
  public static func makeDocument(
    subscriptions: [RSSOPMLSubscription],
    title: String = "RSS Subscriptions"
  ) throws -> Data {
    try prepareDocument(
      subscriptions: subscriptions,
      title: title,
      privacyAction: .redactCredentialQueryValues
    ).data
  }

  public static func makeDocument(
    subscriptions: [RSSOPMLSubscription],
    title: String = "RSS Subscriptions",
    privacyAction: RSSOPMLExportPrivacyAction
  ) throws -> Data {
    try prepareDocument(
      subscriptions: subscriptions,
      title: title,
      privacyAction: privacyAction
    ).data
  }

  public static func scanExportRisks(
    subscriptions: [RSSOPMLSubscription]
  ) -> RSSSubscriptionURLPrivacyReport {
    RSSSubscriptionURLPrivacy.scan(subscriptions: subscriptions)
  }

  public static func prepareDocument(
    subscriptions: [RSSOPMLSubscription],
    title: String = "RSS Subscriptions",
    privacyAction: RSSOPMLExportPrivacyAction
  ) throws -> RSSOPMLExportResult {
    let candidates = try exportCandidates(from: subscriptions)
    let riskReport = scanExportRisks(subscriptions: candidates)
    guard !riskReport.hasBlockingUserInfo else {
      throw RSSReaderError.invalidOPML(
        "无法导出订阅：订阅地址不得包含 URL 用户名或密码。"
      )
    }

    let excludedIndexes: Set<Int>
    switch privacyAction {
    case .preserve, .redactCredentialQueryValues:
      excludedIndexes = []
    case .excludeSubscriptionsWithCredentialQuery:
      excludedIndexes = Set(
        riskReport.findings
          .filter(\.hasSuspectedCredentialQueryParameters)
          .map(\.subscriptionIndex)
      )
    }

    var normalizedSubscriptions: [RSSOPMLSubscription] = []
    var seenURLs = Set<String>()

    for (index, subscription) in candidates.enumerated() {
      guard !excludedIndexes.contains(index) else { continue }
      let preparedSubscription = try applying(privacyAction, to: subscription)
      let feedURL = preparedSubscription.url
      guard seenURLs.insert(feedURL.absoluteString).inserted else { continue }
      normalizedSubscriptions.append(preparedSubscription)
    }

    guard !normalizedSubscriptions.isEmpty else {
      throw RSSReaderError.noOPMLFeeds
    }

    let data = serialize(normalizedSubscriptions, title: title)
    return RSSOPMLExportResult(
      data: data,
      riskReport: riskReport,
      exportedSubscriptionCount: normalizedSubscriptions.count,
      excludedSubscriptionCount: excludedIndexes.count
    )
  }

  private static func exportCandidates(
    from subscriptions: [RSSOPMLSubscription]
  ) throws -> [RSSOPMLSubscription] {
    try subscriptions.map { subscription in
      let feedURL = subscription.url
      guard !RSSSubscriptionURLPrivacy.containsUserInfo(feedURL) else {
        throw RSSReaderError.invalidOPML(
          "无法导出订阅：订阅地址不得包含 URL 用户名或密码。"
        )
      }
      guard isSupported(feedURL) else {
        throw RSSReaderError.invalidOPML(
          "无法导出订阅：地址必须是包含站点域名的 http 或 https URL。"
        )
      }
      if let siteURL = subscription.siteURL,
         RSSSubscriptionURLPrivacy.containsUserInfo(siteURL) {
        throw RSSReaderError.invalidOPML(
          "无法导出订阅：站点地址不得包含 URL 用户名或密码。"
        )
      }
      let fallbackTitle = feedURL.host ?? feedURL.absoluteString
      let feedTitle = sanitized(subscription.title).trimmingCharacters(in: .whitespacesAndNewlines)
      return RSSOPMLSubscription(
        title: feedTitle.isEmpty ? fallbackTitle : feedTitle,
        url: feedURL,
        siteURL: subscription.siteURL.flatMap { isSupported($0) ? $0 : nil }
      )
    }
  }

  private static func applying(
    _ privacyAction: RSSOPMLExportPrivacyAction,
    to subscription: RSSOPMLSubscription
  ) throws -> RSSOPMLSubscription {
    guard privacyAction == .redactCredentialQueryValues else { return subscription }
    guard let feedURL = RSSSubscriptionURLPrivacy.redactingSuspectedCredentialQueryValues(
      in: subscription.url
    ) else {
      throw RSSReaderError.invalidOPML("无法安全脱敏订阅地址。")
    }
    let siteURL: URL?
    if let originalSiteURL = subscription.siteURL {
      guard let redactedSiteURL = RSSSubscriptionURLPrivacy.redactingSuspectedCredentialQueryValues(
        in: originalSiteURL
      ) else {
        throw RSSReaderError.invalidOPML("无法安全脱敏站点地址。")
      }
      siteURL = redactedSiteURL
    } else {
      siteURL = nil
    }
    return RSSOPMLSubscription(
      title: subscription.title,
      url: feedURL,
      siteURL: siteURL
    )
  }

  private static func serialize(
    _ subscriptions: [RSSOPMLSubscription],
    title: String
  ) -> Data {
    let documentTitle = sanitized(title).trimmingCharacters(in: .whitespacesAndNewlines)
    let safeDocumentTitle = documentTitle.isEmpty ? "RSS Subscriptions" : documentTitle
    var lines = [
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      "<opml version=\"2.0\">",
      "  <head>",
      "    <title>\(escaped(safeDocumentTitle))</title>",
      "  </head>",
      "  <body>"
    ]

    for subscription in subscriptions {
      let escapedTitle = escaped(subscription.title)
      let escapedFeedURL = escaped(subscription.url.absoluteString)
      let htmlURLAttribute = subscription.siteURL.map {
        " htmlUrl=\"\(escaped($0.absoluteString))\""
      } ?? ""
      lines.append(
        "    <outline text=\"\(escapedTitle)\" title=\"\(escapedTitle)\" type=\"rss\" xmlUrl=\"\(escapedFeedURL)\"\(htmlURLAttribute)/>"
      )
    }

    lines.append(contentsOf: [
      "  </body>",
      "</opml>",
      ""
    ])
    return Data(lines.joined(separator: "\n").utf8)
  }

  private static func isSupported(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty
    else { return false }
    return true
  }

  private static func sanitized(_ value: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars where isAllowedXMLScalar(scalar.value) {
      scalars.append(scalar)
    }
    return String(scalars)
  }

  private static func isAllowedXMLScalar(_ value: UInt32) -> Bool {
    value == 0x9 || value == 0xA || value == 0xD
      || (0x20...0xD7FF).contains(value)
      || (0xE000...0xFFFD).contains(value)
      || (0x10000...0x10FFFF).contains(value)
  }

  private static func escaped(_ value: String) -> String {
    sanitized(value)
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}
