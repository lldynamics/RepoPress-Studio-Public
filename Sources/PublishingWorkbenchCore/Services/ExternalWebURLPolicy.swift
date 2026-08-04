import Foundation

public enum ExternalWebURLPolicy {
  /// Returns a browser-safe web URL. Local files, custom schemes, remote
  /// plaintext HTTP, and URLs containing user-info are rejected before they
  /// reach NSWorkspace.
  public static func validatedURL(_ url: URL) -> URL? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.host?.nilIfEmpty != nil,
          components.user == nil,
          components.password == nil,
          let candidate = components.url,
          CredentialedEndpointPolicy.isAllowedAIRequestURL(candidate, hasCredential: false) else {
      return nil
    }
    return candidate
  }
}
