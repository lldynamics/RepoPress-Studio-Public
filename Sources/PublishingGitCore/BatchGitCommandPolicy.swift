import Foundation
import PublishingCoreSupport

/// The minimal value needed to assemble batch Git commands. Workbench plan
/// items are intentionally converted to this DTO at the module boundary.
public struct BatchGitCommandItem: Hashable, Sendable {
  public var title: String
  public var repositoryPaths: [String]

  public init(
    title: String,
    repositoryPaths: [String]
  ) {
    self.title = title
    self.repositoryPaths = repositoryPaths
  }
}

/// Builds copyable batch Git commands without executing Git or touching a
/// repository. Paths are deduplicated and sorted for deterministic output.
public struct BatchGitCommandPolicy: Sendable {
  public init() {}

  public func directCommitCommand(
    rootPath: String?,
    items: [BatchGitCommandItem]
  ) -> String? {
    guard let rootPath = rootPath?.nilIfEmpty, !items.isEmpty else {
      return nil
    }

    let root = posixShellQuote(rootPath)
    let paths = shellQuotedPaths(for: items)
    let message = posixShellQuote(commitMessage(for: items))
    return "cd \(root) && git add \(paths) && git commit -m \(message)"
  }

  public func reviewBranchCommands(
    rootPath: String?,
    items: [BatchGitCommandItem],
    now: Date = Date()
  ) -> [String] {
    guard let rootPath = rootPath?.nilIfEmpty, !items.isEmpty else {
      return []
    }

    let root = posixShellQuote(rootPath)
    let branchName = reviewBranchName(for: items, now: now)
    let paths = shellQuotedPaths(for: items)
    let message = posixShellQuote(commitMessage(for: items))

    return [
      "cd \(root)",
      "git switch -c \(posixShellQuote(branchName))",
      "git add \(paths)",
      "git commit -m \(message)",
      "git push -u origin \(posixShellQuote(branchName))",
    ]
  }

  public func reviewBranchName(
    for items: [BatchGitCommandItem],
    now: Date = Date()
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmm"
    let dateToken = formatter.string(from: now)
    return "publish/batch-\(dateToken)-\(items.count)-articles"
  }

  private func commitMessage(for items: [BatchGitCommandItem]) -> String {
    if items.count == 1, let title = items.first?.title.nilIfEmpty {
      return "Publish: \(title)"
    }
    return "Publish: \(items.count) articles"
  }

  private func shellQuotedPaths(for items: [BatchGitCommandItem]) -> String {
    let uniquePaths = Array(Set(items.flatMap(\.repositoryPaths))).sorted()
    return uniquePaths
      .map(posixShellQuote)
      .joined(separator: " ")
  }
}
