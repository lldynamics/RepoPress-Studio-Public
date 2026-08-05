import Foundation

public struct ReleaseLedgerService {
  public init() {}

  public func ledger(
    releaseRecords: [ReleaseRecord],
    deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot]
  ) -> ReleaseLedger {
    let entries = releaseRecords.map { record in
      let deploymentStatus = relevantDeploymentStatus(
        deploymentStatusSnapshots[record.id],
        for: record
      )
      let status = status(for: record, deploymentStatus: deploymentStatus)
      return ReleaseLedgerEntry(
        id: record.id,
        record: record,
        status: status,
        statusMessage: statusMessage(for: record, status: status, deploymentStatus: deploymentStatus),
        deploymentStatus: deploymentStatus,
        rollbackDraft: rollbackDraft(for: record)
      )
    }

    let actionItems = releaseActionItems(for: entries)
    return ReleaseLedger(
      summary: summary(for: entries, actionItemCount: actionItems.count),
      deploymentOverview: deploymentOverview(for: entries),
      actionItems: actionItems,
      entries: entries
    )
  }

  private func relevantDeploymentStatus(
    _ deploymentStatus: DeploymentStatusSnapshot?,
    for record: ReleaseRecord
  ) -> DeploymentStatusSnapshot? {
    guard let deploymentStatus else { return nil }
    switch record.kind {
    case .localWrite, .batchLocalWrite, .directCommit, .remoteDirectCommit, .remoteRollback:
      return deploymentStatus
    case .remotePublishFailure:
      guard record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil else {
        return nil
      }
      let branch = record.branchName?.trimmedForPublishing.nilIfEmpty
      let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty
      return targetBranch == nil || branch == nil || branch == targetBranch ? deploymentStatus : nil
    case .reviewBranch,
         .remoteReviewRequest,
         .remoteReviewWithdrawal:
      return nil
    }
  }

  public func rollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    switch record.kind {
    case .localWrite, .batchLocalWrite:
      return localRollbackDraft(for: record)
    case .directCommit, .remoteDirectCommit:
      return commitRollbackDraft(for: record)
    case .reviewBranch, .remoteReviewRequest:
      return reviewRollbackDraft(for: record)
    case .remotePublishFailure:
      return failedRemotePublishRollbackDraft(for: record)
    case .remoteRollback, .remoteReviewWithdrawal:
      return nil
    }
  }

  private func status(
    for record: ReleaseRecord,
    deploymentStatus: DeploymentStatusSnapshot?
  ) -> ReleaseLedgerStatus {
    if record.kind == .remotePublishFailure,
       record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil {
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
    case .localWrite, .batchLocalWrite:
      return .localOnly
    case .reviewBranch, .remoteReviewRequest:
      return .pendingReview
    case .directCommit, .remoteDirectCommit:
      return .pendingDeployment
    case .remotePublishFailure:
      if record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil {
        return .pendingRemoteRecovery
      }
      return .failed
    case .remoteRollback, .remoteReviewWithdrawal:
      return .succeeded
    }
  }

  private func pendingRetryStatus(for record: ReleaseRecord) -> ReleaseLedgerStatus {
    switch fallbackStatus(for: record) {
    case .pendingDeployment, .deploying, .unknown:
      return .pendingRetry
    case .localOnly, .pendingReview, .pendingRemoteRecovery, .succeeded, .failed, .pendingRetry:
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
      return CoreL10n.text("内容已经写入工作树，还没有形成可追踪的线上发布。")
    case .pendingReview:
      return record.reviewURL == nil
        ? CoreL10n.text("发布分支已经准备好，等待创建或合并 Review。")
        : CoreL10n.text("PR/MR 已准备，等待合并后进入部署。")
    case .pendingDeployment:
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
      return CoreL10n.text("缺少足够信息判断发布状态。")
    }
  }

  private func summary(for entries: [ReleaseLedgerEntry], actionItemCount: Int) -> ReleaseLedgerSummary {
    ReleaseLedgerSummary(
      totalCount: entries.count,
      actionItemCount: actionItemCount,
      localPendingCount: entries.filter { $0.status == .localOnly }.count,
      reviewPendingCount: entries.filter { $0.status == .pendingReview }.count,
      deploymentPendingCount: entries.filter { $0.status == .pendingDeployment || $0.status == .deploying || $0.status == .pendingRetry }.count,
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

  private func partialRemoteRecoveryAction(for entry: ReleaseLedgerEntry) -> ReleaseLedgerActionItem {
    let rollbackCommands = entry.rollbackDraft?.commandLines ?? []
    let commitDetail = entry.record.shortCommitSHA.map {
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
    let highlightedSignals = deploymentSnapshots
      .flatMap(\.signals)
      .filter { $0.level == .failed || $0.level == .running || $0.level == .unknown }
      .prefix(5)

    if pendingRemoteRecoveryCount > 0 {
      return ReleaseDeploymentOverview(
        level: .unknown,
        title: CoreL10n.text("有远端恢复待确认"),
        message: CoreL10n.format("%@ 条远端发布部分完成后中断，需要确认 commit、Review 或回滚方案。", String(pendingRemoteRecoveryCount)),
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

  private func localRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    let paths = record.changedPaths.filter { !$0.trimmedForPublishing.isEmpty }
    guard !paths.isEmpty else {
      return nil
    }

    return ReleaseRollbackDraft(
      title: CoreL10n.format("恢复本地写入：%@", record.draftTitle ?? record.title),
      summary: CoreL10n.text("跟踪文件恢复到 HEAD 并同步取消暂存；本次新增且未跟踪的文件会按记录路径删除。执行前先确认没有其他手动编辑混在这些路径里。"),
      commandLines: paths.map { path in
        let quotedPath = quotedShellPath(path)
        return "if git cat-file -e HEAD:\(quotedPath) >/dev/null 2>&1; then git restore --source=HEAD --staged --worktree -- \(quotedPath); else git restore --staged -- \(quotedPath) >/dev/null 2>&1 || true; git clean -fd -- \(quotedPath); fi"
      },
      changedPaths: paths
    )
  }

  private func commitRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    guard let commitSHA = record.commitSHA?.trimmedForPublishing, !commitSHA.isEmpty else {
      return nil
    }
    let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty ?? record.targetBranch?.trimmedForPublishing.nilIfEmpty ?? "main"
    let shortSHA = String(commitSHA.prefix(8))
    let rollbackBranchName = "rollback/\(shortSHA)"
    let reviewTitle = CoreL10n.format("回滚：%@", record.draftTitle ?? record.title)
    let reviewBody = rollbackReviewBody(for: record, commitSHA: commitSHA, branchName: branchName)
    return ReleaseRollbackDraft(
      title: CoreL10n.format("回滚提交：%@", record.draftTitle ?? record.title),
      summary: CoreL10n.format("基于 %@ 创建 %@，生成 revert 提交来撤销 %@，再用下方回滚草稿发起 PR/MR。", branchName, rollbackBranchName, shortSHA),
      commandLines: [
        "git checkout \(quotedShellPath(branchName))",
        "git pull --ff-only",
        "git checkout -b \(quotedShellPath(rollbackBranchName))",
        "git revert --no-edit \(quotedShellPath(commitSHA))",
        "git push origin \(quotedShellPath(rollbackBranchName))"
      ],
      changedPaths: record.changedPaths,
      reviewBranchName: rollbackBranchName,
      reviewTitle: reviewTitle,
      reviewBody: reviewBody,
      reviewURL: record.reviewURL ?? remoteRollbackReviewURL(
        for: record,
        sourceBranch: rollbackBranchName,
        targetBranch: branchName,
        title: reviewTitle,
        body: reviewBody
      ),
      remoteURL: remoteCommitURL(for: record, commitSHA: commitSHA)
    )
  }

  private func reviewRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    if let reviewURL = record.reviewURL?.trimmedForPublishing, !reviewURL.isEmpty {
      return ReleaseRollbackDraft(
        title: CoreL10n.format("撤回 Review：%@", record.draftTitle ?? record.title),
        summary: CoreL10n.text("关闭或废弃这个 PR/MR；如果已经合并，应改用合并提交或目标分支上的 commit 做 revert。"),
        commandLines: [
          CoreL10n.format("打开 Review 并关闭：%@", reviewURL)
        ],
        changedPaths: record.changedPaths,
        reviewTitle: CoreL10n.format("关闭发布 Review：%@", record.draftTitle ?? record.title),
        reviewBody: closeReviewBody(for: record),
        reviewURL: reviewURL,
        remoteURL: reviewURL
      )
    }

    guard let branchName = record.branchName?.trimmedForPublishing, !branchName.isEmpty else {
      return nil
    }

    return ReleaseRollbackDraft(
      title: CoreL10n.format("撤回发布分支：%@", record.draftTitle ?? record.title),
      summary: CoreL10n.text("删除尚未合并的发布分支。执行前确认该分支没有其他需要保留的提交。"),
      commandLines: [
        "git push origin --delete \(quotedShellPath(branchName))"
      ],
      changedPaths: record.changedPaths,
      reviewBranchName: branchName,
      reviewTitle: CoreL10n.format("关闭发布分支：%@", record.draftTitle ?? record.title),
      reviewBody: closeReviewBody(for: record),
      remoteURL: remoteBranchURL(for: record, branchName: branchName)
    )
  }

  private func failedRemotePublishRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty
    let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty
    if let branchName, branchName != targetBranch {
      return reviewRollbackDraft(for: record)
    }
    return commitRollbackDraft(for: record)
  }

  private func rollbackReviewBody(
    for record: ReleaseRecord,
    commitSHA: String,
    branchName: String
  ) -> String {
    let paths = record.changedPaths.isEmpty
      ? CoreL10n.text("- 未记录变更路径")
      : record.changedPaths.map { "- \($0)" }.joined(separator: "\n")
    return [
      CoreL10n.format("撤销 %@ 在 %@ 上的提交。", commitSHA, branchName),
      "",
      CoreL10n.text("原因："),
      CoreL10n.format("- 回滚发布记录：%@", record.title),
      CoreL10n.format("- 状态摘要：%@", record.summary),
      "",
      CoreL10n.text("变更路径："),
      paths,
      "",
      CoreL10n.text("检查清单："),
      CoreL10n.text("- [ ] 确认此回滚不会删除无关的手动编辑。"),
      CoreL10n.text("- [ ] 合并后验证站点构建和部署。")
    ].joined(separator: "\n")
  }

  private func closeReviewBody(for record: ReleaseRecord) -> String {
    let paths = record.changedPaths.isEmpty
      ? CoreL10n.text("- 未记录变更路径")
      : record.changedPaths.map { "- \($0)" }.joined(separator: "\n")
    return [
      CoreL10n.text("应关闭或取代此发布 Review。"),
      "",
      CoreL10n.text("发布记录："),
      "- \(record.title)",
      "- \(record.summary)",
      "",
      CoreL10n.text("变更路径："),
      paths,
      "",
      CoreL10n.text("检查清单："),
      CoreL10n.text("- [ ] 确认 Review 分支尚未合并。"),
      CoreL10n.text("- [ ] 如果已合并，改为针对目标分支创建 revert 提交。")
    ].joined(separator: "\n")
  }

  private func remoteCommitURL(for record: ReleaseRecord, commitSHA: String) -> String? {
    guard let provider = record.repositoryProvider,
          let owner = record.repoOwner?.trimmedForPublishing, !owner.isEmpty,
          let repo = record.repoName?.trimmedForPublishing, !repo.isEmpty else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = webHost(provider: provider, baseURL: record.repositoryBaseURL)
    switch provider {
    case .github:
      components.path = "/\(owner)/\(repo)/commit/\(commitSHA)"
    case .gitlab:
      components.path = "/\(owner)/\(repo)/-/commit/\(commitSHA)"
    }
    return components.url?.absoluteString
  }

  private func remoteBranchURL(for record: ReleaseRecord, branchName: String) -> String? {
    guard let provider = record.repositoryProvider,
          let owner = record.repoOwner?.trimmedForPublishing, !owner.isEmpty,
          let repo = record.repoName?.trimmedForPublishing, !repo.isEmpty else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = webHost(provider: provider, baseURL: record.repositoryBaseURL)
    switch provider {
    case .github:
      components.path = "/\(owner)/\(repo)/tree/\(branchName)"
    case .gitlab:
      components.path = "/\(owner)/\(repo)/-/tree/\(branchName)"
    }
    return components.url?.absoluteString
  }

  private func remoteRollbackReviewURL(
    for record: ReleaseRecord,
    sourceBranch: String,
    targetBranch: String,
    title: String,
    body: String
  ) -> String? {
    guard let provider = record.repositoryProvider,
          let owner = record.repoOwner?.trimmedForPublishing, !owner.isEmpty,
          let repo = record.repoName?.trimmedForPublishing, !repo.isEmpty else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = webHost(provider: provider, baseURL: record.repositoryBaseURL)
    switch provider {
    case .github:
      components.path = "/\(owner)/\(repo)/compare/\(targetBranch)...\(sourceBranch)"
      components.queryItems = [
        URLQueryItem(name: "quick_pull", value: "1"),
        URLQueryItem(name: "title", value: title),
        URLQueryItem(name: "body", value: body),
      ]
    case .gitlab:
      components.path = "/\(owner)/\(repo)/-/merge_requests/new"
      components.queryItems = [
        URLQueryItem(name: "merge_request[source_branch]", value: sourceBranch),
        URLQueryItem(name: "merge_request[target_branch]", value: targetBranch),
        URLQueryItem(name: "merge_request[title]", value: title),
        URLQueryItem(name: "merge_request[description]", value: body),
      ]
    }
    return components.url?.absoluteString
  }

  private func webHost(provider: RepositoryProvider, baseURL: String?) -> String {
    let fallback: String
    switch provider {
    case .github:
      fallback = "github.com"
    case .gitlab:
      fallback = "gitlab.com"
    }

    guard let host = baseURL.flatMap({ URL(string: $0)?.host }), !host.isEmpty else {
      return fallback
    }

    if provider == .github, host == "api.github.com" {
      return "github.com"
    }
    return host
  }

  private func quotedShellPath(_ value: String) -> String {
    posixShellQuote(value)
  }
}
