/// Provider identifiers remain decodable for saved site profiles after the
/// retired reading analytics feature was removed.
public enum SiteAnalyticsProvider: String, Codable, CaseIterable, Hashable, Sendable {
  case plausible
  case umami
  case cloudflare
}

/// Legacy site configuration retained so saving a workspace does not discard
/// fields written by older releases. This value never contained access tokens.
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
}
