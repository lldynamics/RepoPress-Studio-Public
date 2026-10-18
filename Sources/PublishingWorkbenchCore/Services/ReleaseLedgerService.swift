import Foundation
import PublishingGitCore

public struct ReleaseLedgerService {
  public init() {}

  public func ledger(
    releaseRecords: [ReleaseRecord],
    deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot],
    repositoryHistory: RepositoryReleaseHistorySnapshot? = nil,
    repositoryProfile: SiteProfile? = nil
  ) -> ReleaseLedger {
    let projectedRecords: [ReleaseRecord]
    if let repositoryHistory, let repositoryProfile {
      projectedRecords = ReleaseLedgerGitProjection().records(
        legacyRecords: releaseRecords,
        history: repositoryHistory,
        profile: repositoryProfile
      )
    } else {
      projectedRecords = releaseRecords
    }

    let entries = projectedRecords.map { record in
      let deploymentStatus = relevantDeploymentStatus(
        deploymentStatusSnapshots[record.id],
        for: record
      )
      let status = status(for: record, deploymentStatus: deploymentStatus)
      return ReleaseLedgerEntry(
        id: record.id,
        record: record,
        status: status,
        statusMessage: statusMessage(
          for: record, status: status, deploymentStatus: deploymentStatus),
        deploymentStatus: deploymentStatus,
        rollbackDraft: rollbackDraft(for: record)
      )
    }

    let resolvedLocalWrites = ReleaseLedgerLocalWriteResolution.resolvedIDs(in: releaseRecords)
    let pendingEntries = entries.filter { !resolvedLocalWrites.contains($0.id) }
    let actionItems = releaseActionItems(for: pendingEntries)
    return ReleaseLedger(
      summary: summary(
        for: entries, actionItemCount: actionItems.count,
        localPendingCount: pendingEntries.filter { $0.status == .localOnly }.count),
      deploymentOverview: deploymentOverview(for: entries),
      actionItems: actionItems,
      entries: entries
    )
  }

  private func relevantDeploymentStatus(
    _ deploymentStatus: DeploymentStatusSnapshot?,
    for record: ReleaseRecord
  ) -> DeploymentStatusSnapshot? {
    guard let deploymentStatus,
      deploymentStatus.releaseRecordID == record.id,
      deploymentStatus.profileID == record.siteProfileID
    else { return nil }
    if deploymentStatus.level == .success, !deploymentStatus.verifiesAllArticles(in: record) {
      return nil
    }
    switch record.kind {
    case .remoteDirectCommit, .remoteRollback:
      if deploymentStatus.level == .success {
        guard record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil,
          deploymentStatus.attributionVerified == true
        else {
          return nil
        }
      }
      return deploymentStatus
    case .remoteReviewRequest:
      guard record.reviewStatus?.state == .merged,
        let expectedCommitSHA = record.deploymentCommitSHA,
        deploymentStatus.releaseRecordID == record.id,
        deploymentStatus.expectedCommitSHA?.caseInsensitiveCompare(expectedCommitSHA)
          == .orderedSame,
        deploymentStatus.expectedBranch == record.deploymentBranchName
      else {
        return nil
      }
      if deploymentStatus.level == .success,
        deploymentStatus.attributionVerified != true
      {
        return nil
      }
      return deploymentStatus
    case .localWrite,
      .batchLocalWrite,
      .directCommit,
      .reviewBranch,
      .remotePreviewBranch,
      .remoteReviewWithdrawal:
      return nil
    case .remotePublishFailure:
      guard record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil else {
        return nil
      }
      let branch = record.branchName?.trimmedForPublishing.nilIfEmpty
      let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty
      guard targetBranch == nil || branch == nil || branch == targetBranch else { return nil }
      if deploymentStatus.level == .success,
        deploymentStatus.attributionVerified != true
      {
        return nil
      }
      return deploymentStatus
    }
  }

  private func status(
    for record: ReleaseRecord,
    deploymentStatus: DeploymentStatusSnapshot?
  ) -> ReleaseLedgerStatus {
    if record.kind == .remotePublishFailure,
      record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil
    {
      return .pendingRemoteRecovery
    }

    if let deploymentStatus {
      switch deploymentStatus.level {
      case .success:
        return .succeeded
      case .running:
        return .deploying
      case .failed:
        return .failed
      case .unknown:
        return pendingRetryStatus(for: record)
      }
    }

    return fallbackStatus(for: record)
  }

  private func fallbackStatus(for record: ReleaseRecord) -> ReleaseLedgerStatus {
    switch record.kind {
    case .localWrite, .batchLocalWrite, .directCommit:
      return .localOnly
    case .remotePreviewBranch:
      return .previewOnly
    case .reviewBranch:
      return .pendingReview
    case .remoteReviewRequest:
      switch record.reviewStatus?.state {
      case .open, .locked, .none:
        return .pendingReview
      case .closedWithoutMerge:
        return .reviewWithdrawn
      case .merged:
        return record.deploymentCommitSHA == nil ? .unknown : .pendingDeployment
      }
    case .remoteDirectCommit:
      return record.commitSHA?.trimmedForPublishing.nilIfEmpty == nil
        ? .unknown
        : .pendingDeployment
    case .remotePublishFailure:
      if record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil {
        return .pendingRemoteRecovery
      }
      return .failed
    case .remoteRollback:
      return record.commitSHA?.trimmedForPublishing.nilIfEmpty == nil
        ? .unknown
        : .pendingDeployment
    case .remoteReviewWithdrawal:
      return .reviewWithdrawn
    }
  }

  private func pendingRetryStatus(for record: ReleaseRecord) -> ReleaseLedgerStatus {
    switch fallbackStatus(for: record) {
    case .pendingDeployment, .deploying, .unknown:
      return .pendingRetry
    case .localOnly, .previewOnly, .pendingReview, .reviewWithdrawn, .pendingRemoteRecovery,
      .succeeded, .failed, .pendingRetry:
      return fallbackStatus(for: record)
    }
  }

  private func statusMessage(
    for record: ReleaseRecord,
    status: ReleaseLedgerStatus,
    deploymentStatus: DeploymentStatusSnapshot?
  ) -> String {
    if let deploymentStatus {
      return deploymentStatus.message
    }

    switch status {
    case .localOnly:
      if record.kind == .directCommit {
        return CoreL10n.text("内容已在本地提交，尚未推送到远端，也未触发部署。")
      }
      return CoreL10n.text("内容已经写入工作树，还没有形成可追踪的线上发布。")
    case .previewOnly:
      return CoreL10n.text("预览分支已推送，未合并到正式分支，也未触发正式部署。")
    case .pendingReview:
      if let reviewStatus = record.reviewStatus {
        return reviewStatus.message
      }
      return record.reviewURL == nil
        ? CoreL10n.text("发布分支已经准备好，等待创建或合并 Review。")
        : CoreL10n.text("PR/MR 已准备，等待合并后进入部署。")
    case .reviewWithdrawn:
      if record.kind == .remoteReviewRequest,
        record.reviewStatus?.state == .closedWithoutMerge
      {
        return record.reviewStatus?.message
          ?? CoreL10n.text("PR/MR 已关闭且未合并，不会进入部署检查。")
      }
      return CoreL10n.text("PR/MR 已撤回，未合并到目标分支，也未触发部署。")
    case .pendingDeployment:
      if record.kind == .remoteReviewRequest,
        let reviewStatus = record.reviewStatus
      {
        return reviewStatus.message
      }
      return CoreL10n.text("提交已完成，尚未记录部署检查结果。")
    case .pendingRemoteRecovery:
      return CoreL10n.text("远端发布部分完成后中断；需要确认远端 commit、Review 或回滚方案。")
    case .pendingRetry:
      return deploymentStatus?.message ?? CoreL10n.text("部署检查暂时无法确认，稍后可重试。")
    case .deploying:
      return CoreL10n.text("部署仍在运行。")
    case .succeeded:
      return CoreL10n.text("部署检查已通过。")
    case .failed:
      return CoreL10n.text("发布或部署检查失败，需要处理后重试。")
    case .unknown:
      if record.kind == .remoteReviewRequest,
        record.reviewStatus?.state == .merged
      {
        return record.reviewStatus?.message
          ?? CoreL10n.text("PR/MR 已合并，但缺少可绑定的合并提交，不能开始部署归因。")
      }
      if record.kind == .remoteDirectCommit,
        record.commitSHA?.trimmedForPublishing.nilIfEmpty == nil
      {
        return CoreL10n.text("目标分支内容已核对，但缺少可绑定的 commit，不能确认部署版本。")
      }
      return CoreL10n.text("缺少足够信息判断发布状态。")
    }
  }

  private func summary(
    for entries: [ReleaseLedgerEntry], actionItemCount: Int, localPendingCount: Int
  )
    -> ReleaseLedgerSummary
  {
    ReleaseLedgerSummary(
      totalCount: entries.count,
      actionItemCount: actionItemCount,
      localPendingCount: localPendingCount,
      reviewPendingCount: entries.filter { $0.status == .pendingReview }.count,
      deploymentPendingCount: entries.filter {
        $0.status == .pendingDeployment || $0.status == .deploying || $0.status == .pendingRetry
      }.count,
      remoteRecoveryPendingCount: entries.filter { $0.status == .pendingRemoteRecovery }.count,
      succeededCount: entries.filter { $0.status == .succeeded }.count,
      failedCount: entries.filter { $0.status == .failed }.count,
      rollbackAvailableCount: entries.filter { $0.rollbackDraft != nil }.count
    )
  }

  private func releaseActionItems(for entries: [ReleaseLedgerEntry]) -> [ReleaseLedgerActionItem] {
    entries.compactMap { entry in
      switch entry.status {
      case .failed:
        return failedReleaseAction(for: entry)
      case .pendingRetry:
        return actionItem(
          entry: entry,
          kind: .retryDeploymentCheck,
          priority: .high,
          title: CoreL10n.format("重试部署检查：%@", entry.record.draftTitle ?? entry.record.title),
          summary: entry.statusMessage,
          detail: entry.deploymentStatus?.title ?? CoreL10n.text("部署检查暂时不可确认。"),
          systemImage: ReleaseLedgerStatus.pendingRetry.systemImage,
          remoteURL: diagnosticRemoteURL(for: entry),
          commandLines: []
        )
      case .pendingDeployment:
        return actionItem(
          entry: entry,
          kind: .observeDeployment,
          priority: .medium,
          title: CoreL10n.format("检查部署结果：%@", entry.record.draftTitle ?? entry.record.title),
          summary: entry.statusMessage,
          detail: entry.record.shortCommitSHA.map { "Commit \($0)" } ?? entry.record.summary,
          systemImage: ReleaseLedgerStatus.pendingDeployment.systemImage,
          remoteURL: diagnosticRemoteURL(for: entry),
          commandLines: []
        )
      case .pendingRemoteRecovery:
        return partialRemoteRecoveryAction(for: entry)
      case .deploying:
        return actionItem(
          entry: entry,
          kind: .observeDeployment,
          priority: .medium,
          title: CoreL10n.format("继续观察部署：%@", entry.record.draftTitle ?? entry.record.title),
          summary: entry.statusMessage,
          detail: entry.deploymentStatus?.title ?? entry.record.summary,
          systemImage: ReleaseLedgerStatus.deploying.systemImage,
          remoteURL: diagnosticRemoteURL(for: entry),
          commandLines: []
        )
      case .pendingReview:
        return actionItem(
          entry: entry,
          kind: .completeReview,
          priority: .medium,
          title: CoreL10n.format("处理 Review：%@", entry.record.draftTitle ?? entry.record.title),
          summary: entry.statusMessage,
          detail: entry.record.reviewURL ?? entry.record.branchName ?? entry.record.summary,
          systemImage: ReleaseLedgerStatus.pendingReview.systemImage,
          remoteURL: entry.record.reviewURL ?? entry.rollbackDraft?.remoteURL,
          commandLines: entry.rollbackDraft?.commandLines ?? []
        )
      case .reviewWithdrawn:
        return nil
      case .previewOnly:
        return nil
      case .localOnly:
        return actionItem(
          entry: entry,
          kind: .publishLocalChanges,
          priority: .medium,
          title: CoreL10n.format("提交本地写入：%@", entry.record.draftTitle ?? entry.record.title),
          summary: entry.statusMessage,
          detail: entry.record.changedPaths.prefix(3).joined(separator: " / "),
          systemImage: ReleaseLedgerStatus.localOnly.systemImage,
          remoteURL: nil,
          commandLines: entry.rollbackDraft?.commandLines ?? []
        )
      case .succeeded:
        guard let rollbackDraft = entry.rollbackDraft else {
          return nil
        }
        return actionItem(
          entry: entry,
          kind: .keepRollbackReady,
          priority: .low,
          title: CoreL10n.format("保留回滚预案：%@", entry.record.draftTitle ?? entry.record.title),
          summary: rollbackDraft.summary,
          detail: rollbackDraft.changedPaths.prefix(3).joined(separator: " / "),
          systemImage: "arrow.uturn.backward",
          remoteURL: rollbackDraft.remoteURL,
          commandLines: rollbackDraft.commandLines
        )
      case .unknown:
        return nil
      }
    }
    .sorted {
      if $0.priority.rawValue == $1.priority.rawValue {
        return $0.createdAt > $1.createdAt
      }
      return $0.priority.rawValue < $1.priority.rawValue
    }
  }

  private func failedReleaseAction(for entry: ReleaseLedgerEntry) -> ReleaseLedgerActionItem {
    let rollbackCommands = entry.rollbackDraft?.commandLines ?? []
    return actionItem(
      entry: entry,
      kind: .failedRelease,
      priority: .high,
      title: CoreL10n.format("处理失败发布：%@", entry.record.draftTitle ?? entry.record.title),
      summary: entry.statusMessage,
      detail: entry.deploymentStatus?.title ?? entry.record.summary,
      systemImage: ReleaseLedgerStatus.failed.systemImage,
      remoteURL: diagnosticRemoteURL(for: entry),
      commandLines: rollbackCommands
    )
  }

  private func partialRemoteRecoveryAction(for entry: ReleaseLedgerEntry) -> ReleaseLedgerActionItem
  {
    let rollbackCommands = entry.rollbackDraft?.commandLines ?? []
    let commitDetail =
      entry.record.shortCommitSHA.map {
        CoreL10n.format("远端 commit %@ 已记录，先确认远端状态再决定重试或回滚。", $0)
      } ?? CoreL10n.text("远端发布部分完成，先确认远端分支和变更路径。")
    return actionItem(
      entry: entry,
      kind: .recoverPartialRemotePublish,
      priority: .high,
      title: CoreL10n.format("确认远端部分发布：%@", entry.record.draftTitle ?? entry.record.title),
      summary: entry.record.summary,
      detail: commitDetail,
      systemImage: ReleaseLedgerStatus.pendingRemoteRecovery.systemImage,
      remoteURL: diagnosticRemoteURL(for: entry),
      commandLines: rollbackCommands
    )
  }

  private func diagnosticRemoteURL(for entry: ReleaseLedgerEntry) -> String? {
    let diagnosticSignalURL = entry.deploymentStatus?.diagnosticSignals
      .compactMap { $0.urlText?.trimmedForPublishing.nilIfEmpty }
      .first
    return diagnosticSignalURL
      ?? entry.deploymentStatus?.siteURLText?.trimmedForPublishing.nilIfEmpty
      ?? entry.rollbackDraft?.remoteURL
      ?? entry.record.reviewURL
  }

  private func actionItem(
    entry: ReleaseLedgerEntry,
    kind: ReleaseLedgerActionKind,
    priority: ReleaseLedgerActionPriority,
    title: String,
    summary: String,
    detail: String,
    systemImage: String,
    remoteURL: String?,
    commandLines: [String]
  ) -> ReleaseLedgerActionItem {
    ReleaseLedgerActionItem(
      id: "\(kind.rawValue)-\(entry.id.uuidString)",
      recordID: entry.id,
      kind: kind,
      priority: priority,
      title: title,
      summary: summary,
      detail: detail,
      systemImage: systemImage,
      remoteURL: remoteURL,
      commandLines: commandLines,
      createdAt: entry.record.createdAt
    )
  }

  private func deploymentOverview(for entries: [ReleaseLedgerEntry]) -> ReleaseDeploymentOverview {
    let deploymentSnapshots = entries.compactMap(\.deploymentStatus)
    let failedSnapshots = deploymentSnapshots.filter { $0.level == .failed }
    let runningSnapshots = deploymentSnapshots.filter { $0.level == .running }
    let uncheckedDeploymentCount = entries.filter {
      $0.deploymentStatus == nil && $0.status == .pendingDeployment
    }.count
    let pendingRemoteRecoveryCount = entries.filter { $0.status == .pendingRemoteRecovery }.count
    let lastCheckedAt = deploymentSnapshots.map(\.checkedAt).max()
    let highlightedSignals =
      deploymentSnapshots
      .flatMap(\.signals)
      .filter { $0.level == .failed || $0.level == .running || $0.level == .unknown }
      .prefix(5)

    if pendingRemoteRecoveryCount > 0 {
      return ReleaseDeploymentOverview(
        level: .unknown,
        title: CoreL10n.text("有远端恢复待确认"),
        message: CoreL10n.format(
          "%@ 条远端发布部分完成后中断，需要确认 commit、Review 或回滚方案。", String(pendingRemoteRecoveryCount)),
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: CoreL10n.text("确认远端恢复"),
        nextActionMessage: CoreL10n.text("打开恢复包里的远端链接，确认已写入文件和 commit，再选择重试部署检查或发起回滚 PR/MR。"),
        highlightedSignals: Array(highlightedSignals)
      )
    }

    if !failedSnapshots.isEmpty {
      return ReleaseDeploymentOverview(
        level: .failed,
        title: CoreL10n.text("有部署失败"),
        message: CoreL10n.format("%@ 条部署检查失败，需要查看失败信号后重试。", String(failedSnapshots.count)),
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: CoreL10n.text("处理失败后重试"),
        nextActionMessage: CoreL10n.text("打开失败记录的 Actions、Pipeline 或状态端点，修复后手动检查或等待轮询。"),
        highlightedSignals: Array(highlightedSignals)
      )
    }

    if !runningSnapshots.isEmpty {
      return ReleaseDeploymentOverview(
        level: .running,
        title: CoreL10n.text("部署正在运行"),
        message: CoreL10n.format("%@ 条部署仍在运行，适合继续轮询。", String(runningSnapshots.count)),
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: CoreL10n.text("继续观察部署"),
        nextActionMessage: CoreL10n.text("保持轮询开启，或稍后手动刷新最新发布记录。"),
        highlightedSignals: Array(highlightedSignals)
      )
    }

    if uncheckedDeploymentCount > 0 {
      return ReleaseDeploymentOverview(
        level: .unknown,
        title: CoreL10n.text("等待发布后校验"),
        message: CoreL10n.format("%@ 条线上提交还没有部署检查结果。", String(uncheckedDeploymentCount)),
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: CoreL10n.text("检查待部署记录"),
        nextActionMessage: CoreL10n.text("点击立即轮询或在最新发布记录上执行部署检查。"),
        highlightedSignals: Array(highlightedSignals)
      )
    }

    if deploymentSnapshots.contains(where: { $0.level == .success }) {
      return ReleaseDeploymentOverview(
        level: .success,
        title: CoreL10n.text("发布后校验正常"),
        message: CoreL10n.text("最近部署检查均未发现失败信号。"),
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: CoreL10n.text("保持轮询"),
        nextActionMessage: CoreL10n.text("继续保留轮询或在下次发布后自动检查。"),
        highlightedSignals: Array(highlightedSignals)
      )
    }

    return ReleaseDeploymentOverview(
      level: .unknown,
      title: CoreL10n.text("还没有部署检查"),
      message: CoreL10n.text("发布后可从记录中检查 GitHub Pages、GitLab Pipeline 或自定义状态端点。"),
      checkedRecordCount: 0,
      uncheckedDeploymentCount: uncheckedDeploymentCount,
      failedDeploymentCount: 0,
      runningDeploymentCount: 0,
      lastCheckedAt: nil,
      nextActionTitle: CoreL10n.text("配置部署状态"),
      nextActionMessage: CoreL10n.text("先配置仓库、站点 URL 或状态端点，再执行发布后校验。"),
      highlightedSignals: []
    )
  }

}
