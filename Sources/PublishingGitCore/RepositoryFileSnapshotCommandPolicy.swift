import Foundation

/// Input for planning the read-only Git commands used to snapshot one file
/// from a remote-tracking branch.
public struct RepositoryFileSnapshotCommandInput: Hashable, Sendable {
  public var provider: RepositoryProvider
  public var upstreamName: String
  public var repositoryPath: String
  fileprivate var pathInterpretation: RepositoryFileSnapshotPathInterpretation

  public init(
    provider: RepositoryProvider,
    upstreamName: String,
    repositoryPath: String
  ) {
    self.provider = provider
    self.upstreamName = upstreamName
    self.repositoryPath = repositoryPath
    self.pathInterpretation = .legacyChangedFileDisplay
  }

  /// Creates an input whose path is already the exact destination path.
  /// Unlike the legacy `repositoryPath:` initializer, this never interprets
  /// ` -> ` inside a legal filename as rename display syntax.
  public init(
    provider: RepositoryProvider,
    upstreamName: String,
    exactRepositoryPath: String
  ) {
    self.provider = provider
    self.upstreamName = upstreamName
    self.repositoryPath = exactRepositoryPath
    self.pathInterpretation = .exact
  }

  /// Creates an exact snapshot input from a structured Git change path.
  public init(
    provider: RepositoryProvider,
    upstreamName: String,
    changedPath: RepositoryChangedPath
  ) {
    self.init(
      provider: provider,
      upstreamName: upstreamName,
      exactRepositoryPath: changedPath.destinationPath
    )
  }
}

private enum RepositoryFileSnapshotPathInterpretation: Hashable, Sendable {
  case legacyChangedFileDisplay
  case exact
}

/// The exact argv arrays needed to load remote file content and its provider
/// specific version. The policy never executes Git or touches the filesystem.
public struct RepositoryFileSnapshotCommandPlan: Hashable, Sendable {
  public var repositoryPath: String
  public var contentArguments: [String]
  public var versionArguments: [String]

  public init(
    repositoryPath: String,
    contentArguments: [String],
    versionArguments: [String]
  ) {
    self.repositoryPath = repositoryPath
    self.contentArguments = contentArguments
    self.versionArguments = versionArguments
  }
}

/// Plans safe, provider-specific Git argv arrays for a remote file snapshot.
///
/// Ref and path validation is deliberately local to this policy. This keeps
/// provider adapters from accidentally widening the accepted ref/path syntax
/// while retaining literal path behavior for GitHub and GitLab.
public struct RepositoryFileSnapshotCommandPolicy: Sendable {
  public init() {}

  public func plan(
    for input: RepositoryFileSnapshotCommandInput
  ) -> RepositoryFileSnapshotCommandPlan? {
    guard let fullRef = GitRemoteTrackingReferencePolicy().fullReference(for: input.upstreamName),
          let normalizedPath = normalizedRepositoryPath(
            input.repositoryPath,
            interpretation: input.pathInterpretation
          ) else {
      return nil
    }

    let objectName = "\(fullRef):\(normalizedPath)"
    let contentArguments = [
      "show",
      "--end-of-options",
      objectName,
    ]

    let versionArguments: [String]
    switch input.provider {
    case .github:
      versionArguments = [
        "rev-parse",
        "--verify",
        "--end-of-options",
        objectName,
      ]
    case .gitlab:
      versionArguments = [
        "log",
        "-n",
        "1",
        "--format=%H",
        "--end-of-options",
        fullRef,
        "--",
        ":(literal)\(normalizedPath)",
      ]
    }

    return RepositoryFileSnapshotCommandPlan(
      repositoryPath: normalizedPath,
      contentArguments: contentArguments,
      versionArguments: versionArguments
    )
  }

  private func normalizedRepositoryPath(
    _ repositoryPath: String,
    interpretation: RepositoryFileSnapshotPathInterpretation
  ) -> String? {
    let target: String
    switch interpretation {
    case .legacyChangedFileDisplay:
      if let separatorRange = repositoryPath.range(of: " -> ") {
        // Legacy callers provide one display separator between source and
        // destination. Preserve any later separator as a literal filename
        // sequence (for example, "old.md -> new -> literal.md"). Exact and
        // structured inputs never enter this compatibility branch.
        target = String(repositoryPath[separatorRange.upperBound...])
      } else {
        target = repositoryPath
      }
    case .exact:
      target = repositoryPath
    }
    guard !containsC0OrDEL(target) else {
      return nil
    }

    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("/"),
          !trimmed.contains("\\"),
          !trimmed.contains("://") else {
      return nil
    }

    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { component in component == ".." }) else {
      return nil
    }

    let normalized = components
      .filter { !$0.isEmpty && $0 != "." }
      .map(String.init)
      .joined(separator: "/")

    guard !normalized.isEmpty,
          !normalized.hasPrefix(":") else {
      return nil
    }

    // A scheme or drive prefix is not a repository-relative path. Checking
    // after normalization also catches inputs such as "./C:/file.md".
    guard !hasLeadingSchemeOrDrivePrefix(normalized) else {
      return nil
    }

    return normalized
  }

  private func containsC0OrDEL(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      let codePoint = scalar.value
      return codePoint <= 0x1F || codePoint == 0x7F
    }
  }

  private func hasLeadingSchemeOrDrivePrefix(_ value: String) -> Bool {
    guard let colonIndex = value.firstIndex(of: ":"), colonIndex != value.startIndex else {
      return false
    }

    let suffixStart = value.index(after: colonIndex)
    guard suffixStart < value.endIndex, value[suffixStart] == "/" else {
      return false
    }

    let prefix = value[..<colonIndex]
    guard let first = prefix.unicodeScalars.first,
          isASCIIAlphabetic(first),
          prefix.unicodeScalars.dropFirst().allSatisfy(isASCIIReferenceSchemeCharacter) else {
      return false
    }

    return true
  }

  private func isASCIIAlphabetic(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value >= 0x41 && scalar.value <= 0x5A) ||
      (scalar.value >= 0x61 && scalar.value <= 0x7A)
  }

  private func isASCIIReferenceSchemeCharacter(_ scalar: Unicode.Scalar) -> Bool {
    isASCIIAlphabetic(scalar) ||
      (scalar.value >= 0x30 && scalar.value <= 0x39) ||
      scalar.value == 0x2B ||
      scalar.value == 0x2D ||
      scalar.value == 0x2E
  }
}
