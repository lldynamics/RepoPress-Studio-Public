import Foundation

/// A UI-safe projection of the request endpoint policy. It intentionally
/// exposes only whether setup may proceed and a user-actionable reason; the
/// transport remains the enforcement boundary.
public enum AIConnectionEndpointValidation: Equatable, Sendable {
  case ready
  case invalidURL
  case insecureCredentialURL
  case unsafeHTTPURL

  public var isUsable: Bool { self == .ready }

  public var message: String? {
    switch self {
    case .ready:
      return nil
    case .invalidURL:
      return CoreL10n.text("AI 接口地址无效：请输入带主机名的 HTTP 或 HTTPS 地址。")
    case .insecureCredentialURL:
      return CoreL10n.text("需要 API Key 的 AI 服务必须使用 HTTPS 地址。")
    case .unsafeHTTPURL:
      return CoreL10n.text("HTTP 地址仅允许不带 API Key 的本机回环服务。")
    }
  }

  public static func validate(config: AIProviderConfig) -> Self {
    // Codex app-server authenticates through its dedicated local transport,
    // so it must not be evaluated as an ordinary API endpoint.
    guard !config.usesCodexAppServer else { return .ready }

    let baseURL = config.normalizedBaseURL
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let rawURL = URL(string: baseURL),
      let scheme = rawURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      rawURL.host?.isEmpty == false,
      rawURL.user == nil,
      rawURL.password == nil
    else {
      return .invalidURL
    }

    if config.requiresAPIKey, scheme != "https" {
      return .insecureCredentialURL
    }

    guard let requestURL = config.chatCompletionsURL else {
      return .invalidURL
    }
    guard
      CredentialedEndpointPolicy.isAllowedAIRequestURL(
        requestURL,
        hasCredential: config.requiresAPIKey
      )
    else {
      return config.requiresAPIKey ? .insecureCredentialURL : .unsafeHTTPURL
    }
    return .ready
  }
}
