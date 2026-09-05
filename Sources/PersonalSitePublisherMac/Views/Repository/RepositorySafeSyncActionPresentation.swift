import PublishingWorkbenchCore

enum RepositorySyncReviewKind: Equatable {
  case fastForward
  case rebase
}

/// Pure presentation policy for the repository sync action. Diverged branches
/// never fall through to the fast-forward preset.
struct RepositorySafeSyncActionPresentation: Equatable {
  let title: String
  let help: String
  let isEnabled: Bool
  let reviewKind: RepositorySyncReviewKind?

  static func make(
    hasRepository: Bool,
    branchStatus: RepositoryBranchStatus?,
    isScanning: Bool,
    hasPendingRecoveryOrLifecycle: Bool,
    isRepositoryOperationRunning: Bool,
    isLocalMutationRunning: Bool,
    isRemoteOperationRunning: Bool
  ) -> Self {
    let title = String(localized: "审阅并安全同步远端…")
    guard hasRepository else {
      return Self(
        title: title,
        help: String(localized: "请先选择站点 Git 仓库。"),
        isEnabled: false,
        reviewKind: nil
      )
    }
    guard let branchStatus else {
      return Self(
        title: title,
        help: String(localized: "请先重新扫描仓库，确认当前分支与 upstream。"),
        isEnabled: false,
        reviewKind: nil
      )
    }
    guard !branchStatus.isDetached else {
      return Self(
        title: title,
        help: String(localized: "当前处于 detached HEAD，请先切回站点分支。"),
        isEnabled: false,
        reviewKind: nil
      )
    }
    guard branchStatus.upstreamName?.nilIfEmpty != nil else {
      return Self(
        title: title,
        help: String(localized: "当前分支没有 upstream，请先完成远端配置。"),
        isEnabled: false,
        reviewKind: nil
      )
    }
    guard !hasPendingRecoveryOrLifecycle else {
      return Self(
        title: title,
        help: String(localized: "请先完成或放弃当前 Git 操作，并处理保留的恢复记录。"),
        isEnabled: false,
        reviewKind: nil
      )
    }
    guard branchStatus.behindCount > 0 else {
      if branchStatus.aheadCount > 0 {
        return Self(
          title: String(localized: "本地提交待推送"),
          help: String(localized: "本地只领先远端，无需先拉取或变基。"),
          isEnabled: false,
          reviewKind: nil
        )
      }
      return Self(
        title: String(localized: "当前分支已同步"),
        help: String(localized: "本地 HEAD 与 upstream 已一致。"),
        isEnabled: false,
        reviewKind: nil
      )
    }
    guard !isScanning,
      !isRepositoryOperationRunning,
      !isLocalMutationRunning,
      !isRemoteOperationRunning
    else {
      return Self(
        title: title,
        help: String(localized: "已有扫描、发布或仓库写入正在进行，请等待完成。"),
        isEnabled: false,
        reviewKind: nil
      )
    }
    if branchStatus.aheadCount > 0 {
      return Self(
        title: String(localized: "审阅并变基同步…"),
        help: String(localized: "先冻结当前分叉与工作区；确认后封存未提交改动、对已审阅远端提交变基，再恢复改动。"),
        isEnabled: true,
        reviewKind: .rebase
      )
    }
    return Self(
      title: title,
      help: String(localized: "先刷新远端并展示快进影响；确认前不改变 HEAD 或工作区。"),
      isEnabled: true,
      reviewKind: .fastForward
    )
  }
}
