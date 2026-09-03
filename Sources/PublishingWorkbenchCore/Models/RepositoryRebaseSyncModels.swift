import Foundation

public struct RepositoryRebaseSyncChange: Hashable, Sendable, Identifiable {
  public let status: String
  public let path: String
  public let sourcePath: String?
  public let worktreeBlobOID: String?
  public let worktreeMode: String?
  public let indexBlobOID: String?
  public let indexMode: String?

  public var id: String {
    [status, sourcePath ?? "", path, worktreeBlobOID ?? "", indexBlobOID ?? ""]
      .joined(separator: "\u{1F}")
  }

  public init(
    status: String,
    path: String,
    sourcePath: String? = nil,
    worktreeBlobOID: String? = nil,
    worktreeMode: String? = nil,
    indexBlobOID: String? = nil,
    indexMode: String? = nil
  ) {
    self.status = status
    self.path = path
    self.sourcePath = sourcePath
    self.worktreeBlobOID = worktreeBlobOID
    self.worktreeMode = worktreeMode
    self.indexBlobOID = indexBlobOID
    self.indexMode = indexMode
  }
}

/// Immutable review evidence for the guarded stash/rebase/restore preset.
public struct RepositoryRebaseSyncSnapshot: Hashable, Sendable {
  public let repositoryRoot: String
  public let gitCommonDirectory: String
  public let branch: String
  public let upstream: String
  public let originURL: String
  public let localHeadSHA: String
  public let remoteHeadSHA: String
  public let aheadCount: Int
  public let behindCount: Int
  public let rawStatusFingerprint: String
  public let stagedDiffFingerprint: String
  public let unstagedDiffFingerprint: String
  public let localChanges: [RepositoryRebaseSyncChange]
  public let fingerprint: String

  public init(
    repositoryRoot: String,
    gitCommonDirectory: String,
    branch: String,
    upstream: String,
    originURL: String,
    localHeadSHA: String,
    remoteHeadSHA: String,
    aheadCount: Int,
    behindCount: Int,
    rawStatusFingerprint: String,
    stagedDiffFingerprint: String,
    unstagedDiffFingerprint: String,
    localChanges: [RepositoryRebaseSyncChange],
    fingerprint: String
  ) {
    self.repositoryRoot = repositoryRoot
    self.gitCommonDirectory = gitCommonDirectory
    self.branch = branch
    self.upstream = upstream
    self.originURL = originURL
    self.localHeadSHA = localHeadSHA
    self.remoteHeadSHA = remoteHeadSHA
    self.aheadCount = aheadCount
    self.behindCount = behindCount
    self.rawStatusFingerprint = rawStatusFingerprint
    self.stagedDiffFingerprint = stagedDiffFingerprint
    self.unstagedDiffFingerprint = unstagedDiffFingerprint
    self.localChanges = localChanges
    self.fingerprint = fingerprint
  }
}

public struct RepositoryRebaseSyncConfirmation: Hashable, Sendable, Identifiable {
  public let snapshot: RepositoryRebaseSyncSnapshot
  public var id: String { snapshot.fingerprint }

  public init(snapshot: RepositoryRebaseSyncSnapshot) {
    self.snapshot = snapshot
  }
}

public enum RepositoryRebaseSyncPreparation: Hashable, Sendable {
  case alreadySynchronized(branch: String, headSHA: String)
  case confirmation(RepositoryRebaseSyncConfirmation)
}

public struct RepositoryRebaseSyncResult: Hashable, Sendable {
  public let branch: String
  public let previousHeadSHA: String
  public let rebasedHeadSHA: String
  public let restoredLocalChanges: [String]
  public let stashWasCreated: Bool
  public let stashWasRetained: Bool

  public init(
    branch: String,
    previousHeadSHA: String,
    rebasedHeadSHA: String,
    restoredLocalChanges: [String],
    stashWasCreated: Bool,
    stashWasRetained: Bool
  ) {
    self.branch = branch
    self.previousHeadSHA = previousHeadSHA
    self.rebasedHeadSHA = rebasedHeadSHA
    self.restoredLocalChanges = restoredLocalChanges
    self.stashWasCreated = stashWasCreated
    self.stashWasRetained = stashWasRetained
  }
}

public enum RepositoryRebaseSyncError: Error, LocalizedError, Hashable, Sendable {
  case missingRepositoryRoot
  case invalidRepository(String)
  case detachedHead
  case branchMismatch(expected: String, actual: String)
  case originMismatch(String)
  case upstreamMismatch(expected: String, actual: String)
  case remoteBranchMissing(String)
  case notDiverged(ahead: Int, behind: Int)
  case operationInProgress(String)
  case unsupportedLocalChanges([String])
  case snapshotDrift
  case gitFailed(command: String, output: String)
  case rebaseConflict(stashCommitSHA: String?, paths: [String])
  case stashRestoreConflict(stashCommitSHA: String, paths: [String])
  case partial(stashCommitSHA: String?, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot: "未选择本地仓库。"
    case .invalidRepository(let message): "Git 仓库状态无效：\(message)"
    case .detachedHead: "当前处于 detached HEAD，不能安全变基。"
    case .branchMismatch(let expected, let actual):
      "当前分支 \(actual) 与目标分支 \(expected) 不一致。"
    case .originMismatch(let value): "origin 与当前站点仓库不匹配：\(value)"
    case .upstreamMismatch(let expected, let actual):
      "upstream 必须是 \(expected)，当前为 \(actual)。"
    case .remoteBranchMissing(let branch): "远端分支 origin/\(branch) 不存在。"
    case .notDiverged(let ahead, let behind):
      "变基预设仅用于本地与远端已分叉（领先 \(ahead)，落后 \(behind)）。"
    case .operationInProgress(let operation):
      "仓库正在进行 \(operation)，请先完成或中止后再同步。"
    case .unsupportedLocalChanges(let paths):
      "存在无法安全封存的本地改动：\(paths.joined(separator: "、"))"
    case .snapshotDrift: "审阅后的仓库、远端或本地改动已变化，请重新确认。"
    case .gitFailed(let command, let output): "Git 命令失败：\(command)\n\(output)"
    case .rebaseConflict(let stashCommitSHA, let paths):
      "变基遇到冲突：\(paths.joined(separator: "、"))。本地改动尚未恢复\(stashDescription(stashCommitSHA))。"
    case .stashRestoreConflict(let stashCommitSHA, let paths):
      "变基已完成，恢复本地改动时遇到冲突：\(paths.joined(separator: "、"))。恢复 stash \(stashCommitSHA.prefix(12)) 已保留。"
    case .partial(let stashCommitSHA, let message):
      "变基同步未完整结束：\(message)\(stashDescription(stashCommitSHA))"
    }
  }

  private func stashDescription(_ sha: String?) -> String {
    guard let sha else { return "" }
    return "；恢复 stash \(sha.prefix(12)) 已保留"
  }
}
