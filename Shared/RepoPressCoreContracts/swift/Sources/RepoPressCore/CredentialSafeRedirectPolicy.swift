import Foundation

/// Pure redirect decision shared by app-owned URLSession delegates.
/// Refusing an unsafe redirect leaves the original 3xx response with the caller.
public enum CredentialSafeRedirectPolicy {
  private static let credentialHeaders = ["Authorization", "PRIVATE-TOKEN", "X-API-Key"]

  public static func redirectedRequest(
    originalRequest: URLRequest?,
    responseURL: URL?,
    proposedRequest: URLRequest
  ) -> URLRequest? {
    let requests = [originalRequest, proposedRequest].compactMap { $0 }
    let hasCredentials = requests.contains { request in
      credentialHeaders.contains { request.value(forHTTPHeaderField: $0)?.isEmpty == false }
    }
    let hasBody = requests.contains { request in
      let method = request.httpMethod?.uppercased() ?? "GET"
      return method != "GET" && method != "HEAD"
        && (request.httpBody != nil || request.httpBodyStream != nil)
    }
    guard hasCredentials || hasBody else { return proposedRequest }
    guard let originalURL = originalRequest?.url ?? responseURL,
      let destinationURL = proposedRequest.url,
      isAllowed(from: originalURL, to: destinationURL, hasCredentials: hasCredentials),
      isAllowed(from: responseURL ?? originalURL, to: destinationURL, hasCredentials: hasCredentials)
    else { return nil }
    return proposedRequest
  }

  private static func isAllowed(from source: URL, to destination: URL, hasCredentials: Bool) -> Bool {
    guard let scheme = source.scheme?.lowercased(),
      let host = source.host?.lowercased(), !host.isEmpty,
      scheme == destination.scheme?.lowercased(),
      host == destination.host?.lowercased(),
      (source.port ?? defaultPort(scheme)) == (destination.port ?? defaultPort(scheme)),
      source.user == nil, source.password == nil,
      destination.user == nil, destination.password == nil
    else { return false }
    if scheme == "https" { return true }
    // Preserve local AI requests without credentials, as on macOS.
    return !hasCredentials && scheme == "http"
      && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
  }

  private static func defaultPort(_ scheme: String) -> Int? {
    switch scheme {
    case "https": 443
    case "http": 80
    default: nil
    }
  }
}
