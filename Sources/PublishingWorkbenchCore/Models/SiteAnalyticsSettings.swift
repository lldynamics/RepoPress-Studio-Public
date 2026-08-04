import Foundation

/// Per-site configuration for read-only traffic reporting.
///
/// Access tokens are deliberately not part of this value. They are stored in
/// the Keychain, scoped to the site profile and analytics provider.
public struct SiteAnalyticsSettings: Codable, Hashable, Sendable {
  public var isEnabled: Bool
  public var provider: SiteAnalyticsProvider
  public var baseURL: String
  public var siteID: String
  public var dateRangeDays: Int

  public init(
    isEnabled: Bool = false,
    provider: SiteAnalyticsProvider = .plausible,
    baseURL: String = "https://plausible.io",
    siteID: String = "",
    dateRangeDays: Int = 28
  ) {
    self.isEnabled = isEnabled
    self.provider = provider
    self.baseURL = baseURL
    self.siteID = siteID
    self.dateRangeDays = dateRangeDays
  }

  public static let `default` = SiteAnalyticsSettings()

  public var normalizedDateRangeDays: Int {
    min(max(dateRangeDays, 7), 90)
  }

  public var configuration: SiteAnalyticsConfiguration? {
    guard isEnabled else { return nil }
    let normalizedSiteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSiteID.isEmpty else { return nil }

    switch provider {
    case .plausible, .umami:
      let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: normalizedBaseURL), url.scheme != nil, url.host != nil else {
        return nil
      }
      if provider == .plausible {
        return .plausible(baseURL: url, siteID: normalizedSiteID)
      }
      return .umami(baseURL: url, websiteID: normalizedSiteID)
    case .cloudflare:
      return .cloudflare(zoneID: normalizedSiteID)
    }
  }

  public var identifierLabel: String {
    switch provider {
    case .plausible:
      return "Plausible Site ID"
    case .umami:
      return "Umami Website ID"
    case .cloudflare:
      return "Cloudflare Zone ID"
    }
  }

  public var requiresBaseURL: Bool {
    provider != .cloudflare
  }

  public var providerDisplayName: String {
    provider.displayName
  }
}
