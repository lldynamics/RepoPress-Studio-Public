import Foundation
import PublishingCoreSupport

/// Foundation-only input for choosing a repository synchronization command
/// plan. A nil `hasGitDirectory` means that no scan report is available yet.
public struct RepositorySyncCommandInput: Hashable, Sendable {
  public var rootPath: String?
  public var hasGitDirectory: Bool?
  public var preferredBranch: String?
  public var branchStatus: RepositoryBranchStatus?

  public init(
    rootPath: String?,
    hasGitDirectory: Bool?,
    preferredBranch: String?,
    branchStatus: RepositoryBranchStatus? = nil
  ) {
    self.rootPath = rootPath
    self.hasGitDirectory = hasGitDirectory
    self.preferredBranch = preferredBranch
    self.branchStatus = branchStatus
  }
}

/// The non-localized branch decision selected by the synchronization policy.
public enum RepositorySyncCommandDecision: Hashable, Sendable {
  case scanRequired
  case missingGitDirectory
  case branchUnknown
  case detachedHead(fallbackBranch: String)
  case missingUpstream(branch: String)
  case diverged(aheadCount: Int, behindCount: Int)
  case behind(behindCount: Int)
  case ahead(aheadCount: Int)
  case synchronized
}

/// Pure command output. Localized titles, summaries, and notes remain a
/// Workbench concern while command construction stays reusable in GitCore.
public struct RepositorySyncCommandPolicyResult: Hashable, Sendable {
  public var decision: RepositorySyncCommandDecision
  public var commands: [String]

  public init(
    decision: RepositorySyncCommandDecision,
    commands: [String]
  ) {
    self.decision = decision
    self.commands = commands
  }
}

/// Chooses safe, copyable Git commands without executing Git or reading the
/// filesystem. Callers own the localized presentation of each decision.
public struct RepositorySyncCommandPolicy: Sendable {
  public init() {}

  public func plan(
    for input: RepositorySyncCommandInput
  ) -> RepositorySyncCommandPolicyResult? {
    guard let rootPath = input.rootPath?.nilIfEmpty else {
      return nil
    }

    let cdCommand = "cd \(posixShellQuote(rootPath))"
    guard let hasGitDirectory = input.hasGitDirectory else {
      return result(
        .scanRequired,
        commands: [
          cdCommand,
          "git status --short --branch",
        ]
      )
    }

    guard hasGitDirectory else {
      return result(
        .missingGitDirectory,
        commands: [
          cdCommand,
          "git status --short --branch",
        ]
      )
    }

    guard let branchStatus = input.branchStatus else {
      return result(
        .branchUnknown,
        commands: [
          cdCommand,
          "git status --short --branch",
          "git remote -v",
        ]
      )
    }

    if branchStatus.isDetached {
      let fallbackBranch = input.preferredBranch?.nilIfEmpty ?? "main"
      return result(
        .detachedHead(fallbackBranch: fallbackBranch),
        commands: [
          cdCommand,
          "git status --short --branch",
          "git switch \(posixShellQuote(fallbackBranch))",
        ]
      )
    }

    let branchName = branchStatus.branchName ?? input.preferredBranch
    let branch = branchName?.nilIfEmpty ?? "main"

    guard branchStatus.upstreamName != nil else {
      return result(
        .missingUpstream(branch: branch),
        commands: [
          cdCommand,
          "git status --short --branch",
          "git fetch --prune",
          "git branch --set-upstream-to=\(posixShellQuote("origin/\(branch)")) \(posixShellQuote(branch))",
        ]
      )
    }

    if branchStatus.aheadCount > 0 && branchStatus.behindCount > 0 {
      return result(
        .diverged(
          aheadCount: branchStatus.aheadCount,
          behindCount: branchStatus.behindCount
        ),
        commands: [
          cdCommand,
          "git fetch --prune",
          "git status --short --branch",
          "git pull --ff-only",
        ]
      )
    }

    if branchStatus.behindCount > 0 {
      return result(
        .behind(behindCount: branchStatus.behindCount),
        commands: [
          cdCommand,
          "git fetch --prune",
          "git pull --ff-only",
        ]
      )
    }

    if branchStatus.aheadCount > 0 {
      return result(
        .ahead(aheadCount: branchStatus.aheadCount),
        commands: [
          cdCommand,
          "git status --short --branch",
          "git push",
        ]
      )
    }

    return result(
      .synchronized,
      commands: [
        cdCommand,
        "git status --short --branch",
      ]
    )
  }

  private func result(
    _ decision: RepositorySyncCommandDecision,
    commands: [String]
  ) -> RepositorySyncCommandPolicyResult {
    RepositorySyncCommandPolicyResult(decision: decision, commands: commands)
  }
}
