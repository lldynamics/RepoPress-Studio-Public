import Foundation

/// Path scoping for one-article publishes, and the pure path and status
/// classifications shared by the worktree review and its commit.
extension RepositoryWorktreePublishService {
  func repositoryStatus(root: URL) throws -> String {
    try output(["status", "--porcelain=v1", "-z", "--untracked-files=all"], root: root)
  }

  func worktreeIsClean(root: URL, pathScope: [String]?) throws -> Bool {
    try output(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"]
        + pathspecs(for: pathScope),
      root: root
    ).isEmpty
  }

  /// A scope is a sorted set of validated repository-relative file paths.
  /// An empty scope can never publish anything, so it is rejected outright.
  func normalizedPathScope(_ pathScope: [String]?, root: URL) throws -> [String]? {
    guard let pathScope else { return nil }
    let paths = Array(Set(pathScope)).sorted()
    guard !paths.isEmpty else { throw RepositoryWorktreePublishError.noChanges }
    for path in paths {
      try validateRelativePath(path, root: root)
    }
    return paths
  }

  /// Literal pathspecs keep names containing `*`, `?` or `:` from expanding.
  func pathspecs(for pathScope: [String]?) -> [String] {
    pathScope.map { $0.map { ":(literal)\($0)" } } ?? ["."]
  }

  func isSensitive(_ path: String) -> Bool {
    let components = path.lowercased().split(separator: "/").map(String.init)
    guard let filename = components.last else { return true }
    if components.contains(where: { [".ssh", ".aws", ".gnupg"].contains($0) }) {
      return true
    }
    if filename == ".env" || filename.hasPrefix(".env.") {
      return true
    }
    if [
      ".npmrc", ".pypirc", ".netrc", "credentials", "credentials.json",
      "id_rsa", "id_ed25519",
    ].contains(filename) {
      return true
    }
    if filename.hasPrefix("service-account") && filename.hasSuffix(".json") {
      return true
    }
    return ["pem", "key", "p12", "pfx", "mobileprovision"]
      .contains((filename as NSString).pathExtension)
  }

  func isUnmerged(status: String) -> Bool {
    ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(status)
  }

  func isStaged(status: String) -> Bool {
    guard let first = status.first else { return false }
    return first != " " && first != "?"
  }

  func entryKind(status: String) -> RepositoryWorktreePublishEntryKind {
    if status.contains("R") { return .renamed }
    if status.contains("C") { return .copied }
    if status.contains("D") { return .deleted }
    if status.contains("T") { return .typeChanged }
    if status == "??" || status.contains("A") { return .added }
    return .modified
  }
}
