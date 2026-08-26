import Foundation

/// The upstream identity needed to plan a remote comparison.  The value is
/// deliberately kept independent from repository I/O and provider details.
public struct RepositoryRemoteDiffCommandInput: Hashable, Sendable {
  public var upstreamName: String

  public init(upstreamName: String) {
    self.upstreamName = upstreamName
  }
}

/// Exact argv for the remote changed-file list and its per-file line diff.
/// The plan stores the canonical ref so every command in one comparison uses
/// the same unambiguous remote-tracking object.
public struct RepositoryRemoteDiffCommandPlan: Hashable, Sendable {
  public let fullRef: String
  public let changedFilesArguments: [String]

  init(fullRef: String, changedFilesArguments: [String]) {
    self.fullRef = fullRef
    self.changedFilesArguments = changedFilesArguments
  }

  /// Plans a line diff using the exact source and destination paths.
  public func fileDiffArguments(for file: RepositoryChangedFile) -> [String]? {
    fileDiffArguments(for: file.changedPath)
  }

  /// Plans a line diff using a structured path without trimming or
  /// interpreting path contents.
  public func fileDiffArguments(for changedPath: RepositoryChangedPath) -> [String]? {
    let paths: [String]
    switch changedPath {
    case let .single(destinationPath):
      paths = [destinationPath]
    case let .sourceAndDestination(sourcePath, destinationPath):
      paths = [sourcePath, destinationPath]
    }

    guard paths.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
      return nil
    }

    return [
      "diff",
      "-M",
      "-C",
      "--end-of-options",
      "HEAD...\(fullRef)",
      "--",
    ] + paths.map { ":(literal)" + $0 }
  }

  /// Legacy string boundary for callers that have not migrated to the
  /// structured path model. This treats the value as one literal path.
  public func fileDiffArguments(for repositoryPath: String) -> [String]? {
    fileDiffArguments(for: .single(repositoryPath))
  }
}

/// Plans safe, literal-path remote comparison commands without executing Git.
public struct RepositoryRemoteDiffCommandPolicy: Sendable {
  public init() {}

  public func plan(
    for input: RepositoryRemoteDiffCommandInput
  ) -> RepositoryRemoteDiffCommandPlan? {
    guard let fullRef = GitRemoteTrackingReferencePolicy().fullReference(for: input.upstreamName) else {
      return nil
    }

    return RepositoryRemoteDiffCommandPlan(
      fullRef: fullRef,
      changedFilesArguments: [
        "diff",
        "-M",
        "-C",
        "--name-status",
        "-z",
        "--end-of-options",
        "HEAD...\(fullRef)",
        "--",
      ]
    )
  }
}
