import Foundation

public enum RSSSubscriptionURLLocation: String, Equatable, Sendable {
  case feed
  case site
}

public struct RSSSubscriptionURLPrivacyFinding: Equatable, Sendable {
  public let subscriptionIndex: Int
  public let subscriptionTitle: String
  public let location: RSSSubscriptionURLLocation
  public let containsUserInfo: Bool
  public let suspectedCredentialQueryParameterNames: [String]
  public let redactedURL: String

  public init(
    subscriptionIndex: Int,
    subscriptionTitle: String,
    location: RSSSubscriptionURLLocation,
    containsUserInfo: Bool,
    suspectedCredentialQueryParameterNames: [String],
    redactedURL: String
  ) {
    self.subscriptionIndex = subscriptionIndex
    self.subscriptionTitle = subscriptionTitle
    self.location = location
    self.containsUserInfo = containsUserInfo
    self.suspectedCredentialQueryParameterNames = suspectedCredentialQueryParameterNames
    self.redactedURL = redactedURL
  }

  public var hasSuspectedCredentialQueryParameters: Bool {
    !suspectedCredentialQueryParameterNames.isEmpty
  }
}

public struct RSSSubscriptionURLPrivacyReport: Equatable, Sendable {
  public let findings: [RSSSubscriptionURLPrivacyFinding]

  public init(findings: [RSSSubscriptionURLPrivacyFinding]) {
    self.findings = findings
  }

  public var hasRisks: Bool { !findings.isEmpty }

  public var hasBlockingUserInfo: Bool {
    findings.contains(where: \.containsUserInfo)
  }

  public var hasSuspectedCredentialQueryParameters: Bool {
    findings.contains(where: \.hasSuspectedCredentialQueryParameters)
  }

  public var affectedSubscriptionCount: Int {
    Set(findings.map(\.subscriptionIndex)).count
  }

  public var suspectedCredentialQueryParameterNames: [String] {
    var seen = Set<String>()
    return findings
      .flatMap(\.suspectedCredentialQueryParameterNames)
      .filter { seen.insert($0.lowercased()).inserted }
  }
}

/// Detects credential-bearing subscription URLs without retaining credential values in the report.
public enum RSSSubscriptionURLPrivacy {
  public static func scan(
    subscriptions: [RSSOPMLSubscription]
  ) -> RSSSubscriptionURLPrivacyReport {
    let findings = subscriptions.enumerated().flatMap { index, subscription in
      var findings: [RSSSubscriptionURLPrivacyFinding] = []
      if let finding = finding(
        for: subscription.url,
        subscriptionIndex: index,
        subscriptionTitle: subscription.title,
        location: .feed
      ) {
        findings.append(finding)
      }
      if let siteURL = subscription.siteURL,
         let finding = finding(
           for: siteURL,
           subscriptionIndex: index,
           subscriptionTitle: subscription.title,
           location: .site
         ) {
        findings.append(finding)
      }
      return findings
    }
    return RSSSubscriptionURLPrivacyReport(findings: findings)
  }

  public static func containsUserInfo(_ url: URL) -> Bool {
    url.user != nil || url.password != nil
  }

  public static func suspectedCredentialQueryParameterNames(in url: URL) -> [String] {
    guard let queryItems = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false
    )?.queryItems else {
      return []
    }

    var seen = Set<String>()
    return queryItems.compactMap { item in
      guard isSuspectedCredentialParameterName(item.name) else { return nil }
      let key = item.name.lowercased()
      return seen.insert(key).inserted ? item.name : nil
    }
  }

  public static func redactingSuspectedCredentialQueryValues(
    in url: URL,
    replacement: String = "REDACTED"
  ) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.queryItems = components.queryItems?.map { item in
      guard isSuspectedCredentialParameterName(item.name) else { return item }
      return URLQueryItem(name: item.name, value: replacement)
    }
    return components.url
  }

  private static func finding(
    for url: URL,
    subscriptionIndex: Int,
    subscriptionTitle: String,
    location: RSSSubscriptionURLLocation
  ) -> RSSSubscriptionURLPrivacyFinding? {
    let containsUserInfo = containsUserInfo(url)
    let parameterNames = suspectedCredentialQueryParameterNames(in: url)
    guard containsUserInfo || !parameterNames.isEmpty else { return nil }

    return RSSSubscriptionURLPrivacyFinding(
      subscriptionIndex: subscriptionIndex,
      subscriptionTitle: subscriptionTitle,
      location: location,
      containsUserInfo: containsUserInfo,
      suspectedCredentialQueryParameterNames: parameterNames,
      redactedURL: redactedDescription(of: url)
    )
  }

  private static func redactedDescription(of url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "订阅地址（无法安全显示）"
    }
    components.user = nil
    components.password = nil
    components.fragment = nil
    // A finding means the URL is already sensitive. Reports keep parameter
    // names for diagnosis but never retain any query value, including values
    // whose custom parameter names were not recognized by the heuristic.
    components.queryItems = components.queryItems?.map { item in
      URLQueryItem(name: item.name, value: item.value == nil ? nil : "REDACTED")
    }
    return components.url?.absoluteString ?? "订阅地址（无法安全显示）"
  }

  private static func isSuspectedCredentialParameterName(_ name: String) -> Bool {
    let normalized = name.unicodeScalars.reduce(into: "") { result, scalar in
      guard CharacterSet.alphanumerics.contains(scalar) else { return }
      result.unicodeScalars.append(contentsOf: String(scalar).lowercased().unicodeScalars)
    }

    if normalized.contains("token")
      || normalized.contains("signature")
      || normalized.contains("credential")
      || normalized.contains("authorization")
      || normalized.contains("authentication")
      || normalized.contains("password")
      || normalized.contains("passwd")
      || normalized.contains("secret")
      || normalized.contains("apikey")
      || normalized.contains("accesskey")
      || normalized.contains("privatekey")
      || normalized.contains("clientkey")
      || normalized.contains("consumerkey")
      || normalized.contains("subscriptionkey")
      || normalized.hasPrefix("oauth")
      || (normalized.hasPrefix("auth") && !normalized.hasPrefix("author")) {
      return true
    }

    return [
      "key",
      "sig",
      "jwt",
    ].contains(normalized)
  }
}
