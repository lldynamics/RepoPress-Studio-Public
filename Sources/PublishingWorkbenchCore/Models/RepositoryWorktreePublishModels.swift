import Foundation
import PublishingCoreSupport

public enum RepositoryWorktreePublishEntryKind: String, Hashable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case typeChanged

  public var localizedName: String {
    switch self {
    case .added: CoreL10n.text("新增")
    case .modified: CoreL10n.text("修改")
    case .deleted: CoreL10n.text("删除")
    case .renamed: CoreL10n.text("重命名")
    case .copied: CoreL10n.text("复制")
    case .typeChanged: CoreL10n.text("类型变化")
    }
  }
}

/// One exact path state included in a repository-wide publish review.
/// Existing files freeze the Git blob and mode that must appear in the index;
/// deleted paths intentionally carry no target blob or mode.
public struct RepositoryWorktreePublishEntry: Hashable, Sendable, Identifiable {
  public let kind: RepositoryWorktreePublishEntryKind
  public let status: String
  public let path: String
  public let sourcePath: String?
  public let byteSize: Int64
  public let mode: String?
  public let blobOID: String?

  public var id: String {
    [status, sourcePath ?? "", path].joined(separator: "\u{1F}")
  }

  public init(
    kind: RepositoryWorktreePublishEntryKind,
    status: String,
    path: String,
    sourcePath: String? = nil,
    byteSize: Int64 = 0,
    mode: String? = nil,
    blobOID: String? = nil
  ) {
    self.kind = kind
    self.status = status
    self.path = path
    self.sourcePath = sourcePath
    self.byteSize = byteSize
    self.mode = mode
    self.blobOID = blobOID
  }
}

/// Read-only evidence shown to the user before any index, commit, or remote
/// mutation. Equality is the confirmation token: every field is recomputed
/// immediately before staging.
public struct RepositoryWorktreePublishSnapshot: Hashable, Sendable {
  public let repositoryRoot: String
  public let gitCommonDirectory: String
  public let branch: String
  public let headSHA: String
  public let originURL: String
  public let remoteBranchSHA: String
  public let statusFingerprint: String
  public let entries: [RepositoryWorktreePublishEntry]

  public var paths: [String] {
    Array(
      Set(
        entries.flatMap { entry in
          [entry.path, entry.sourcePath].compactMap { $0 }
        })
    ).sorted()
  }

  public init(
    repositoryRoot: String,
    gitCommonDirectory: String,
    branch: String,
    headSHA: String,
    originURL: String,
    remoteBranchSHA: String,
    statusFingerprint: String,
    entries: [RepositoryWorktreePublishEntry]
  ) {
    self.repositoryRoot = repositoryRoot
    self.gitCommonDirectory = gitCommonDirectory
    self.branch = branch
    self.headSHA = headSHA
    self.originURL = originURL
    self.remoteBranchSHA = remoteBranchSHA
    self.statusFingerprint = statusFingerprint
    self.entries = entries
  }
}

/// Immutable article identity captured alongside a repository-wide publish.
/// The target is intentionally independent from the mutable draft model so a
/// later deployment check can prove exactly which article was published.
public struct RepositoryWorktreeArticleVerificationTarget: Hashable, Sendable {
  public let draftID: UUID
  public let title: String
  public let summary: String
  public let coverAltText: String?
  public let markdownPath: String

  public init(
    draftID: UUID,
    title: String,
    summary: String,
    coverAltText: String? = nil,
    markdownPath: String
  ) {
    self.draftID = draftID
    self.title = title
    self.summary = summary
    self.coverAltText = coverAltText
    self.markdownPath = markdownPath
  }
}

public struct RepositoryWorktreePublishConfirmation: Hashable, Sendable, Identifiable {
  public let snapshot: RepositoryWorktreePublishSnapshot
  public let commitMessage: String
  public let safetyReport: RepositoryPublishSafetyReport
  public let sitePreflightResult: RepositoryPublishPreflightResult?
  public let articleVerificationTarget: RepositoryWorktreeArticleVerificationTarget?

  public var id: String {
    [
      snapshot.repositoryRoot,
      snapshot.headSHA,
      snapshot.statusFingerprint,
      commitMessage,
      safetyReport.diagnostics.map(\.id).joined(separator: "\u{1D}"),
      sitePreflightResult.map { String(describing: $0.outcome) } ?? "",
      articleVerificationTarget.map { $0.draftID.uuidString } ?? "",
    ]
    .joined(separator: "\u{1E}")
  }

  public init(
    snapshot: RepositoryWorktreePublishSnapshot,
    commitMessage: String,
    safetyReport: RepositoryPublishSafetyReport = RepositoryPublishSafetyReport(),
    sitePreflightResult: RepositoryPublishPreflightResult? = nil,
    articleVerificationTarget: RepositoryWorktreeArticleVerificationTarget? = nil
  ) {
    self.snapshot = snapshot
    self.commitMessage = commitMessage
    self.safetyReport = safetyReport
    self.sitePreflightResult = sitePreflightResult
    self.articleVerificationTarget = articleVerificationTarget
  }
}

public struct RepositoryWorktreePublishResult: Hashable, Sendable {
  public let commitSHA: String
  public let branch: String
  public let pushed: Bool
  public let remoteCommitSHA: String?
  public let committedPaths: [String]

  public init(
    commitSHA: String,
    branch: String,
    pushed: Bool,
    remoteCommitSHA: String?,
    committedPaths: [String]
  ) {
    self.commitSHA = commitSHA
    self.branch = branch
    self.pushed = pushed
    self.remoteCommitSHA = remoteCommitSHA
    self.committedPaths = committedPaths
  }
}

public enum RepositoryWorktreePublishError: LocalizedError, Equatable, Sendable {
  case missingRepositoryRoot
  case invalidRepository(String)
  case dirtyIndex([String])
  case detachedHead
  case branchMismatch(expected: String, actual: String)
  case originMismatch(String)
  case remoteBranchMissing(String)
  case remoteOutOfDate(local: String, remote: String)
  case unmergedPaths([String])
  case unsupportedPaths([String])
  case oversizedPaths([String])
  case sensitivePaths([String])
  case noChanges
  case snapshotDrift
  case sitePreflightFailed(String)
  case stagedVerificationFailed
  case invalidCommitMessage
  case gitFailed(command: String, output: String)
  case commitSucceededButPushFailed(commitSHA: String, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot:
      "未选择本地仓库。"
    case .invalidRepository(let value):
      "Git 仓库状态无效：\(value)"
    case .dirtyIndex(let paths):
      "已有暂存内容，不能整体发布：\(paths.joined(separator: "、"))"
    case .detachedHead:
      "当前处于 detached HEAD，不能发布。"
    case .branchMismatch(let expected, let actual):
      "当前分支 \(actual) 与目标分支 \(expected) 不一致。"
    case .originMismatch(let value):
      "origin 与当前站点仓库不匹配：\(value)"
    case .remoteBranchMissing(let branch):
      "远端分支 origin/\(branch) 不存在，不能把全文件发布当作首次推送。"
    case .remoteOutOfDate(let local, let remote):
      "本地 HEAD（\(local.prefix(8))）与远端（\(remote.prefix(8))）不一致。请前往“站点 → 概览 → 同步建议”审阅并安全同步，然后重新发布。"
    case .unmergedPaths(let paths):
      "存在未合并路径：\(paths.joined(separator: "、"))"
    case .unsupportedPaths(let paths):
      "包含符号链接、子模块、特殊文件或 Git LFS 路径，已停止发布：\(paths.joined(separator: "、"))"
    case .oversizedPaths(let paths):
      "包含超过 100 MB 的文件，已停止发布：\(paths.joined(separator: "、"))"
    case .sensitivePaths(let paths):
      "包含可能保存密钥或凭据的敏感路径，已停止发布：\(paths.joined(separator: "、"))"
    case .noChanges:
      "工作区没有可发布的变更。"
    case .snapshotDrift:
      "文件、分支或远端状态已变化，请重新打开完整清单确认。"
    case .sitePreflightFailed(let message):
      "站点发布前检查失败：\(message)"
    case .stagedVerificationFailed:
      "暂存结果与已审阅清单不一致；已停止提交并恢复空暂存区。"
    case .invalidCommitMessage:
      "提交说明不能为空。"
    case .gitFailed(let command, let output):
      "Git 命令失败：\(command)\n\(output)"
    case .commitSucceededButPushFailed(let commitSHA, let message):
      "本地提交 \(commitSHA.prefix(8)) 已完成，但没有确认推送成功：\(message)"
    }
  }
}
