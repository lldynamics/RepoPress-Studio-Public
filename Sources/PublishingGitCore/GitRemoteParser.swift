import Foundation
import PublishingCoreSupport

/// Parses Git remotes without executing Git or consulting repository state.
public enum GitRemoteParser {
  public static func parseRepositoryRemote(_ remoteURL: String) -> RepositoryRemote? {
    let trimmed = remoteURL.trimmedForPublishing
    guard !trimmed.isEmpty else { return nil }

    if trimmed.range(of: "://", options: .caseInsensitive) == nil {
      guard let components = scpComponents(from: trimmed) else { return nil }
      return makeRepositoryRemote(
        original: trimmed,
        host: components.host,
        path: components.path,
        sanitizedRemoteURL: "\(components.host):\(components.path)"
      )
    }

    guard let components = urlComponents(from: trimmed) else { return nil }
    return makeRepositoryRemote(
      original: trimmed,
      host: components.host,
      path: components.path,
      sanitizedRemoteURL: components.sanitizedRemoteURL
    )
  }

  /// Returns the remote portion of a validated Git upstream name such as
  /// `origin/main`. This mirrors the Workbench compatibility behavior while
  /// keeping validation independent from any Git process or filesystem state.
  public static func remoteName(fromUpstreamName upstreamName: String) -> String? {
    let trimmed = upstreamName.trimmedForPublishing
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("/"),
          !trimmed.contains("\\"),
          !trimmed.contains(".."),
          !trimmed.contains("://"),
          let slashIndex = trimmed.firstIndex(of: "/") else {
      return nil
    }
    let remote = String(trimmed[..<slashIndex]).trimmedForPublishing
    guard !remote.isEmpty,
          remote.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
      return nil
    }
    return remote
  }

  private static func urlComponents(
    from remoteURL: String
  ) -> (host: String, path: String, sanitizedRemoteURL: String)? {
    guard let url = URLComponents(string: remoteURL),
          url.scheme?.trimmedForPublishing.nilIfEmpty != nil,
          let host = url.host?.trimmedForPublishing.nilIfEmpty,
          !host.contains("/"),
          !host.contains(":") else {
      return nil
    }

    let path = url.path
    guard validRepositoryPath(path, requiresLeadingSlash: true) else {
      return nil
    }

    var sanitized = url
    sanitized.user = nil
    sanitized.password = nil
    sanitized.query = nil
    sanitized.fragment = nil
    guard let sanitizedRemoteURL = sanitized.string?.nilIfEmpty else {
      return nil
    }
    return (host: host, path: path, sanitizedRemoteURL: sanitizedRemoteURL)
  }

  private static func scpComponents(
    from remoteURL: String
  ) -> (host: String, path: String)? {
    guard let colonIndex = scpHostPathSeparator(in: remoteURL) else {
      return nil
    }

    let hostPart = String(remoteURL[..<colonIndex])
    let host = hostPart.components(separatedBy: "@").last?.trimmedForPublishing ?? ""
    let pathStart = remoteURL.index(after: colonIndex)
    let path = String(remoteURL[pathStart...])
    guard !host.isEmpty,
          !host.contains("@"),
          !host.contains(":"),
          !host.contains("/"),
          !host.contains(where: { $0.isWhitespace || $0.isNewline }),
          validRepositoryPath(path, requiresLeadingSlash: false) else {
      return nil
    }
    return (host: host, path: path)
  }

  private static func scpHostPathSeparator(in remoteURL: String) -> String.Index? {
    let searchStart = remoteURL.lastIndex(of: "@").map { remoteURL.index(after: $0) }
      ?? remoteURL.startIndex
    return remoteURL[searchStart...].firstIndex(of: ":")
  }

  private static func validRepositoryPath(
    _ path: String,
    requiresLeadingSlash: Bool
  ) -> Bool {
    guard !path.isEmpty,
          !path.contains("?"),
          !path.contains("#"),
          !path.contains(where: { $0.isWhitespace || $0.isNewline }),
          !path.hasSuffix("/"),
          !path.contains("//") else {
      return false
    }
    if requiresLeadingSlash && !path.hasPrefix("/") {
      return false
    }
    if !requiresLeadingSlash && path.hasPrefix("/") {
      return false
    }
    let componentPath = requiresLeadingSlash ? String(path.dropFirst()) : path
    let components = componentPath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count >= 2 else { return false }
    return !components.contains { component in
      component == "." || component == ".." || component.isEmpty
    }
  }

  private static func makeRepositoryRemote(
    original: String,
    host: String,
    path: String,
    sanitizedRemoteURL: String
  ) -> RepositoryRemote? {
    let pathComponents = path
      .split(separator: "/")
      .map(String.init)
    guard pathComponents.count >= 2,
          let provider = repositoryProvider(forHost: host) else {
      return nil
    }

    var repositoryName = pathComponents.last ?? ""
    if repositoryName.hasSuffix(".git") {
      repositoryName.removeLast(4)
    }
    let owner = pathComponents.dropLast().joined(separator: "/")
    guard !owner.isEmpty,
          !repositoryName.isEmpty,
          !original.isEmpty else {
      return nil
    }

    return RepositoryRemote(
      remoteURL: sanitizedRemoteURL,
      provider: provider,
      repositoryBaseURL: repositoryBaseURL(provider: provider, host: host),
      owner: owner,
      name: repositoryName
    )
  }

  private static func repositoryProvider(forHost host: String) -> RepositoryProvider? {
    let lowercaseHost = host.lowercased()
    if lowercaseHost.contains("github") {
      return .github
    }
    if lowercaseHost.contains("gitlab") {
      return .gitlab
    }
    return nil
  }

  private static func repositoryBaseURL(
    provider: RepositoryProvider,
    host: String
  ) -> String {
    switch provider {
    case .github:
      return host.lowercased() == "github.com"
        ? RepositoryProvider.github.defaultBaseURL
        : "https://\(host)"
    case .gitlab:
      return "https://\(host)"
    }
  }
}
