import Foundation

/// The Git sequencer state that must be explicitly finished or aborted before
/// normal repository operations may safely continue.
public enum RepositoryOperationLifecycleKind: String, Codable, Hashable, Sendable {
  case none
  case merge
  case rebase
  /// Unmerged index entries without a Git sequencer marker, for example a
  /// conflict while restoring a stash. It requires resolution but has no safe
  /// generic `continue` or `abort` command.
  case unmergedIndex
  case ambiguous

  public var displayName: String {
    switch self {
    case .none:
      return "无进行中的 Git 操作"
    case .merge:
      return "合并"
    case .rebase:
      return "变基"
    case .unmergedIndex:
      return "待恢复的冲突"
    case .ambiguous:
      return "无法确认的 Git 操作"
    }
  }

  public var canComplete: Bool {
    self == .merge || self == .rebase
  }
}

/// A read-only, bounded description of a merge or rebase lifecycle. The
/// unresolved count comes from the Git index, rather than working-tree marker
/// text, so staging every conflict does not accidentally erase the operation.
public struct RepositoryOperationLifecycle: Codable, Hashable, Sendable {
  public var rootPath: String
  public var branchName: String?
  public var kind: RepositoryOperationLifecycleKind
  public var unresolvedConflictCount: Int
  public var diagnostic: String?

  public init(
    rootPath: String,
    branchName: String? = nil,
    kind: RepositoryOperationLifecycleKind = .none,
    unresolvedConflictCount: Int = 0,
    diagnostic: String? = nil
  ) {
    self.rootPath = rootPath
    self.branchName = branchName
    self.kind = kind
    self.unresolvedConflictCount = max(0, unresolvedConflictCount)
    self.diagnostic = diagnostic
  }

  public var isOperationInProgress: Bool {
    kind != .none
  }

  public var isCompletionReady: Bool {
    kind.canComplete && unresolvedConflictCount == 0
  }
}

/// Errors exposed by the explicit merge/rebase lifecycle actions. Every case
/// is safe to present in the UI and intentionally avoids exposing raw paths or
/// repository configuration values in its primary localized description.
public enum RepositoryOperationLifecycleError: Error, LocalizedError, Hashable, Sendable {
  case repositoryUnavailable
  case invalidRepository(String)
  case noOperationInProgress
  case unexpectedOperation(expected: RepositoryOperationLifecycleKind, actual: RepositoryOperationLifecycleKind)
  case ambiguousOperation
  case unresolvedConflicts(Int)
  case invalidCommitMessage
  case repositoryChanged
  case commandFailed(operation: String, terminated: Int32, output: String)
  case operationDidNotFinish(RepositoryOperationLifecycleKind)

  public var errorDescription: String? {
    switch self {
    case .repositoryUnavailable:
      return "未找到可用的本地 Git 仓库。"
    case let .invalidRepository(message):
      return "Git 仓库状态无效：\(message)"
    case .noOperationInProgress:
      return "当前没有需要完成或放弃的 Git 合并/变基操作。"
    case let .unexpectedOperation(expected, actual):
      return "当前正在进行\(actual.displayName)，不能执行\(expected.displayName)操作。"
    case .ambiguousOperation:
      return "检测到多个 Git 操作状态，无法安全继续。请在终端检查仓库后重试。"
    case let .unresolvedConflicts(count):
      return "仍有 \(count) 个未解决冲突。请先逐个确认最终内容并暂存。"
    case .invalidCommitMessage:
      return "合并提交说明不能为空或超过安全长度。"
    case .repositoryChanged:
      return "仓库在操作期间发生变化，请重新扫描后再处理。"
    case let .commandFailed(operation, terminated, output):
      let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return "\(operation)失败（退出码：\(terminated)）：\(detail.isEmpty ? "请检查 Git 工作区状态。" : detail)"
    case let .operationDidNotFinish(kind):
      return "\(kind.displayName)命令已返回，但 Git 操作状态尚未结束。请重新扫描后再处理。"
    }
  }
}
