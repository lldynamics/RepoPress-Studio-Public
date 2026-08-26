import Foundation

/// The exact Git argv arrays needed to inspect one working-tree change.
///
/// Tracked changes use two commands so that index and working-tree content can
/// be presented independently.  The arrays are ordered staged first, then
/// unstaged.  Untracked files use Git's no-index form and deliberately keep
/// the filesystem path raw (without a `:(literal)` pathspec wrapper).
public struct RepositoryLocalDiffCommandPlan: Hashable, Sendable {
  public let argumentsInExecutionOrder: [[String]]

  init(argumentsInExecutionOrder: [[String]]) {
    self.argumentsInExecutionOrder = argumentsInExecutionOrder
  }
}

/// Plans local Git diff commands without executing Git or touching the
/// filesystem.
public struct RepositoryLocalDiffCommandPolicy: Sendable {
  public init() {}

  public func plan(for file: RepositoryChangedFile) -> RepositoryLocalDiffCommandPlan? {
    switch file.changedPath {
    case let .single(path):
      guard isUsablePath(path) else {
        return nil
      }

      if file.kind == .untracked {
        guard isSafeUntrackedPath(path) else {
          return nil
        }
        return RepositoryLocalDiffCommandPlan(
          argumentsInExecutionOrder: [[
            "diff",
            "--no-index",
            "--",
            "/dev/null",
            path,
          ]]
        )
      }

      return trackedPlan(paths: [path])

    case let .sourceAndDestination(sourcePath, destinationPath):
      guard file.kind != .untracked,
            isUsablePath(sourcePath),
            isUsablePath(destinationPath) else {
        return nil
      }

      return trackedPlan(paths: [sourcePath, destinationPath])
    }
  }

  private func trackedPlan(paths: [String]) -> RepositoryLocalDiffCommandPlan {
    let literalPaths = paths.map { ":(literal)\($0)" }
    return RepositoryLocalDiffCommandPlan(
      argumentsInExecutionOrder: [
        ["diff", "-M", "-C", "--cached", "--"] + literalPaths,
        ["diff", "-M", "-C", "--"] + literalPaths,
      ]
    )
  }

  private func isUsablePath(_ path: String) -> Bool {
    !path.isEmpty && !path.contains("\0")
  }

  private func isSafeUntrackedPath(_ path: String) -> Bool {
    guard !path.hasPrefix("/") else {
      return false
    }

    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains { component in
      component == "." || component == ".."
    }
  }
}
