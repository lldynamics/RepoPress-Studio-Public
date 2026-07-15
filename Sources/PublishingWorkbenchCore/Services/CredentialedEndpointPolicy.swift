import Foundation

enum CredentialedEndpointPolicy {
  static func isSecureAPIBaseURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
      && url.host?.isEmpty == false
      && url.user == nil
      && url.password == nil
      && url.query == nil
      && url.fragment == nil
  }

  static func isSecureRequestURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
      && url.host?.isEmpty == false
      && url.user == nil
      && url.password == nil
  }

  static func isAllowedAIRequestURL(_ url: URL, hasCredential: Bool) -> Bool {
    if isSecureRequestURL(url) {
      return true
    }
    guard !hasCredential,
          url.scheme?.lowercased() == "http",
          url.user == nil,
          url.password == nil,
          let host = url.host else {
      return false
    }
    return isStrictLoopbackHost(host)
  }

  static func isAllowedCredentialRedirect(from sourceURL: URL, to destinationURL: URL) -> Bool {
    guard isSecureRequestURL(sourceURL), isSecureRequestURL(destinationURL) else {
      return false
    }
    return isSameOrigin(sourceURL, destinationURL)
  }

  static func isAllowedSensitiveBodyRedirect(from sourceURL: URL, to destinationURL: URL) -> Bool {
    isAllowedAIRequestURL(sourceURL, hasCredential: false)
      && isAllowedAIRequestURL(destinationURL, hasCredential: false)
      && isSameOrigin(sourceURL, destinationURL)
  }

  private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    normalizedOrigin(for: lhs) == normalizedOrigin(for: rhs)
  }

  private static func normalizedOrigin(for url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(),
          let host = url.host?.lowercased() else {
      return nil
    }
    let defaultPort = scheme == "https" ? 443 : 80
    return "\(scheme)://\(host):\(url.port ?? defaultPort)"
  }

  private static func isStrictLoopbackHost(_ rawHost: String) -> Bool {
    let host = rawHost
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .lowercased()
    if host == "localhost" || host == "::1" {
      return true
    }

    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4,
          octets.allSatisfy({ !$0.isEmpty && UInt8($0) != nil }) else {
      return false
    }
    return octets[0] == "127"
  }
}
