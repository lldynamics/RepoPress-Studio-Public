import Foundation

/// A read-only recommendation derived from a selected local site repository.
///
/// The proposal never writes to the repository. Callers can present its
/// evidence for confirmation, then apply it to a copied profile.
public struct RepositoryAutoConfigurationProposal: Equatable, Sendable {
  public let detectedKind: SiteKind?
  public let evidence: [String]
  public let isGitRepository: Bool
  public let contentRoot: String
  public let assetRoot: String
  public let frontMatterStyle: FrontMatterStyle
  public let markdownPathPattern: String

  public init(
    detectedKind: SiteKind?,
    evidence: [String],
    isGitRepository: Bool,
    contentRoot: String,
    assetRoot: String,
    frontMatterStyle: FrontMatterStyle,
    markdownPathPattern: String
  ) {
    self.detectedKind = detectedKind
    self.evidence = evidence
    self.isGitRepository = isGitRepository
    self.contentRoot = contentRoot
    self.assetRoot = assetRoot
    self.frontMatterStyle = frontMatterStyle
    self.markdownPathPattern = markdownPathPattern
  }

  /// Applies only repository-discoverable publishing values. Unknown
  /// repositories retain the supplied profile's existing publishing rules.
  public func applying(to profile: SiteProfile, repositoryURL: URL) -> SiteProfile {
    var configuredProfile = profile
    if let detectedKind {
      configuredProfile.applyPublishingDefaults(for: detectedKind)
      configuredProfile.contentRoot = contentRoot
      configuredProfile.assetRoot = assetRoot
      configuredProfile.frontMatterStyle = frontMatterStyle
      configuredProfile.markdownPathPattern = markdownPathPattern
    }
    configuredProfile.rememberLocalRepositoryRoot(repositoryURL)
    return configuredProfile
  }
}

/// Shared validation for repository-relative publishing rules shown before a
/// profile is persisted. The same invariants are enforced again by preflight
/// after path templates are rendered for an article.
public enum RepositoryPublishingRuleValidation {
  public static func isValid(
    contentRoot: String,
    markdownPathPattern: String
  ) -> Bool {
    let root = contentRoot.trimmedForPublishing
    let pattern = markdownPathPattern.trimmedForPublishing
    guard isSafeRelativePath(root, allowsCurrentDirectory: true),
      isSafeRelativePath(pattern, allowsCurrentDirectory: false),
      pattern.contains("{slug}")
    else {
      return false
    }

    let normalizedRoot = root.normalizedRelativePath()
    let normalizedPattern = pattern.normalizedRelativePath()
    return normalizedRoot.isEmpty
      || normalizedPattern == normalizedRoot
      || normalizedPattern.hasPrefix(normalizedRoot + "/")
  }

  private static func isSafeRelativePath(
    _ path: String,
    allowsCurrentDirectory: Bool
  ) -> Bool {
    if allowsCurrentDirectory, path == "." {
      return true
    }
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !path.hasPrefix("~"),
      !path.contains("\\"),
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      path.range(
        of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
        options: .regularExpression
      ) == nil
    else {
      return false
    }
    return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }
}
