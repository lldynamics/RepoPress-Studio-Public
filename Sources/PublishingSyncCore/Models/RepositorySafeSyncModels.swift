import Foundation

public struct RepositorySafeSyncChange: Hashable, Sendable, Identifiable {
  public let status: String
  public let path: String
  public let sourcePath: String?
  public let blobOID: String?
  public let mode: String?
  public let isDeletion: Bool

  public var id: String {
    [status, sourcePath ?? "", path, blobOID ?? "", mode ?? ""].joined(separator: "\u{1F}")
  }

  public init(
    status: String,
    path: String,
    sourcePath: String? = nil,
    blobOID: String? = nil,
    mode: String? = nil,
    isDeletion: Bool = false
  ) {
    self.status = status
    self.path = path
    self.sourcePath = sourcePath
    self.blobOID = blobOID
    self.mode = mode
    self.isDeletion = isDeletion
  }
}

public struct RepositorySafeSyncCollision: Hashable, Sendable, Identifiable {
  public let path: String
  public let localBlobOID: String
  public let remoteBlobOID: String
  public let mode: String

  public var id: String { path }

  public init(path: String, localBlobOID: String, remoteBlobOID: String, mode: String) {
    self.path = path
    self.localBlobOID = localBlobOID
    self.remoteBlobOID = remoteBlobOID
    self.mode = mode
  }
}

/// Immutable evidence collected after the limited fetch and before the user
/// accepts a safe fast-forward. `fingerprint` is deliberately comprehensive:
/// apply recomputes every field before it changes the worktree.
public struct RepositorySafeSyncSnapshot: Hashable, Sendable {
  public let repositoryRoot: String
  public let gitCommonDirectory: String
  public let branch: String
  public let upstream: String
  public let originURL: String
  public let localHeadSHA: String
  public let remoteHeadSHA: String
  public let behindCount: Int
  public let rawStatusFingerprint: String
  public let remoteDiffFingerprint: String
  public let localChanges: [RepositorySafeSyncChange]
  public let remoteChanges: [RepositorySafeSyncChange]
  public let identicalUntrackedCollisions: [RepositorySafeSyncCollision]
  public let fingerprint: String

  public init(
    repositoryRoot: String,
    gitCommonDirectory: String,
    branch: String,
    upstream: String,
    originURL: String,
    localHeadSHA: String,
    remoteHeadSHA: String,
    behindCount: Int,
    rawStatusFingerprint: String,
    remoteDiffFingerprint: String,
    localChanges: [RepositorySafeSyncChange],
    remoteChanges: [RepositorySafeSyncChange],
    identicalUntrackedCollisions: [RepositorySafeSyncCollision],
    fingerprint: String
  ) {
    self.repositoryRoot = repositoryRoot
    self.gitCommonDirectory = gitCommonDirectory
    self.branch = branch
    self.upstream = upstream
    self.originURL = originURL
    self.localHeadSHA = localHeadSHA
    self.remoteHeadSHA = remoteHeadSHA
    self.behindCount = behindCount
    self.rawStatusFingerprint = rawStatusFingerprint
    self.remoteDiffFingerprint = remoteDiffFingerprint
    self.localChanges = localChanges
    self.remoteChanges = remoteChanges
    self.identicalUntrackedCollisions = identicalUntrackedCollisions
    self.fingerprint = fingerprint
  }
}

public struct RepositorySafeSyncConfirmation: Hashable, Sendable, Identifiable {
  public let snapshot: RepositorySafeSyncSnapshot

  public var id: String { snapshot.fingerprint }

  public init(snapshot: RepositorySafeSyncSnapshot) {
    self.snapshot = snapshot
  }
}

public enum RepositorySafeSyncPreparation: Hashable, Sendable {
  case alreadySynchronized(branch: String, headSHA: String)
  case confirmation(RepositorySafeSyncConfirmation)
}

public struct RepositorySafeSyncResult: Hashable, Sendable {
  public let previousHeadSHA: String
  public let synchronizedHeadSHA: String
  public let branch: String
  public let preservedLocalPaths: [String]
  public let reconciledCollisionPaths: [String]
  public let remoteAdvancedAgain: Bool
  public let recoveryArchiveURL: URL?

  public init(
    previousHeadSHA: String,
    synchronizedHeadSHA: String,
    branch: String,
    preservedLocalPaths: [String],
    reconciledCollisionPaths: [String],
    remoteAdvancedAgain: Bool,
    recoveryArchiveURL: URL?
  ) {
    self.previousHeadSHA = previousHeadSHA
    self.synchronizedHeadSHA = synchronizedHeadSHA
    self.branch = branch
    self.preservedLocalPaths = preservedLocalPaths
    self.reconciledCollisionPaths = reconciledCollisionPaths
    self.remoteAdvancedAgain = remoteAdvancedAgain
    self.recoveryArchiveURL = recoveryArchiveURL
  }
}

public enum RepositorySafeSyncError: Error, LocalizedError, Hashable, Sendable {
  case missingRepositoryRoot
  case invalidRepository(String)
  case detachedHead
  case branchMismatch(expected: String, actual: String)
  case originMismatch(String)
  case upstreamMismatch(expected: String, actual: String)
  case remoteBranchMissing(String)
  case notBehind(ahead: Int, behind: Int)
  case stagedChanges([String])
  case unmergedPaths([String])
  case unsafeLocalChanges([String])
  case unsafeRemoteChanges([String])
  case collisionMismatch([String])
  case snapshotDrift
  case gitFailed(command: String, output: String)
  case recoveryRequired(recoveryDirectory: String, message: String)
  case partial(recoveryDirectory: String, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot: "未选择本地仓库。"
    case .invalidRepository(let message): "Git 仓库状态无效：\(message)"
    case .detachedHead: "当前处于 detached HEAD，不能安全同步。"
    case .branchMismatch(let expected, let actual): "当前分支 \(actual) 与目标分支 \(expected) 不一致。"
    case .originMismatch(let value): "origin 与当前站点仓库不匹配：\(value)"
    case .upstreamMismatch(let expected, let actual): "upstream 必须是 \(expected)，当前为 \(actual)。"
    case .remoteBranchMissing(let branch): "远端分支 origin/\(branch) 不存在。"
    case .notBehind(let ahead, let behind):
      "仅支持本地未领先且落后远端的 fast-forward（当前领先 \(ahead)，落后 \(behind)）。"
    case .stagedChanges(let paths): "存在暂存内容，不能安全同步：\(paths.joined(separator: "、"))"
    case .unmergedPaths(let paths): "存在未合并路径：\(paths.joined(separator: "、"))"
    case .unsafeLocalChanges(let paths): "本地改动不能安全保留：\(paths.joined(separator: "、"))"
    case .unsafeRemoteChanges(let paths): "远端改动与本地工作区交叠：\(paths.joined(separator: "、"))"
    case .collisionMismatch(let paths): "同路径文件内容或权限不完全一致：\(paths.joined(separator: "、"))"
    case .snapshotDrift: "审阅后的仓库、远端或文件状态已变化，请重新确认。"
    case .gitFailed(let command, let output): "Git 命令失败：\(command)\n\(output)"
    case .recoveryRequired(_, let message): "同步未完成，已保留恢复备份：\(message)"
    case .partial(let recoveryDirectory, let message):
      recoveryDirectory.isEmpty
        ? "同步结果不完整且不会回退 HEAD：\(message)"
        : "同步结果不完整，已保留恢复备份：\(message)"
    }
  }
}
