import Foundation

public enum ReleaseLedgerStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case localOnly
  case pendingReview
  case pendingDeployment
  case pendingRemoteRecovery
  case pendingRetry
  case deploying
  case succeeded
  case failed
  case unknown

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .localOnly:
      return "本地待处理"
    case .pendingReview:
      return "等待合并"
    case .pendingDeployment:
      return "等待部署检查"
    case .pendingRemoteRecovery:
      return "远端待确认"
    case .pendingRetry:
      return "待重试"
    case .deploying:
      return "部署中"
    case .succeeded:
      return "已上线"
    case .failed:
      return "失败"
    case .unknown:
      return "未知"
    }
  }

  public var systemImage: String {
    switch self {
    case .localOnly:
      return "externaldrive.badge.clock"
    case .pendingReview:
      return "arrow.triangle.pull"
    case .pendingDeployment:
      return "clock.badge.questionmark"
    case .pendingRemoteRecovery:
      return "icloud.and.arrow.up"
    case .pendingRetry:
      return "wifi.exclamationmark"
    case .deploying:
      return "hourglass"
    case .succeeded:
      return "checkmark.seal"
    case .failed:
      return "xmark.octagon"
    case .unknown:
      return "questionmark.circle"
    }
  }
}

public struct ReleaseRollbackDraft: Codable, Hashable, Sendable {
  public var title: String
  public var summary: String
  public var commandLines: [String]
  public var changedPaths: [String]
  public var reviewBranchName: String?
  public var reviewTitle: String?
  public var reviewBody: String?
  public var reviewURL: String?
  public var remoteURL: String?

  public init(
    title: String,
    summary: String,
    commandLines: [String],
    changedPaths: [String],
    reviewBranchName: String? = nil,
    reviewTitle: String? = nil,
    reviewBody: String? = nil,
    reviewURL: String? = nil,
    remoteURL: String? = nil
  ) {
    self.title = title
    self.summary = summary
    self.commandLines = commandLines
    self.changedPaths = changedPaths
    self.reviewBranchName = reviewBranchName
    self.reviewTitle = reviewTitle
    self.reviewBody = reviewBody
    self.reviewURL = reviewURL
    self.remoteURL = remoteURL
  }
}

public struct ReleaseLedgerEntry: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var record: ReleaseRecord
  public var status: ReleaseLedgerStatus
  public var statusMessage: String
  public var deploymentStatus: DeploymentStatusSnapshot?
  public var rollbackDraft: ReleaseRollbackDraft?

  public init(
    id: UUID,
    record: ReleaseRecord,
    status: ReleaseLedgerStatus,
    statusMessage: String,
    deploymentStatus: DeploymentStatusSnapshot?,
    rollbackDraft: ReleaseRollbackDraft?
  ) {
    self.id = id
    self.record = record
    self.status = status
    self.statusMessage = statusMessage
    self.deploymentStatus = deploymentStatus
    self.rollbackDraft = rollbackDraft
  }
}

public struct ReleaseRecoveryPackage: Codable, Hashable, Sendable {
  public var title: String
  public var status: ReleaseLedgerStatus
  public var summary: String
  public var remoteURL: String?
  public var rollbackReviewURL: String?
  public var nextActions: [String]
  public var commandLines: [String]
  public var reviewTitle: String?
  public var reviewBody: String?
  public var changedPaths: [String]
  public var clipboardMarkdown: String

  public init(
    title: String,
    status: ReleaseLedgerStatus,
    summary: String,
    remoteURL: String?,
    rollbackReviewURL: String? = nil,
    nextActions: [String] = [],
    commandLines: [String],
    reviewTitle: String?,
    reviewBody: String?,
    changedPaths: [String],
    clipboardMarkdown: String
  ) {
    self.title = title
    self.status = status
    self.summary = summary
    self.remoteURL = remoteURL
    self.rollbackReviewURL = rollbackReviewURL
    self.nextActions = nextActions
    self.commandLines = commandLines
    self.reviewTitle = reviewTitle
    self.reviewBody = reviewBody
    self.changedPaths = changedPaths
    self.clipboardMarkdown = clipboardMarkdown
  }

  private enum CodingKeys: String, CodingKey {
    case title
    case status
    case summary
    case remoteURL
    case rollbackReviewURL
    case nextActions
    case commandLines
    case reviewTitle
    case reviewBody
    case changedPaths
    case clipboardMarkdown
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decode(String.self, forKey: .title)
    status = try container.decode(ReleaseLedgerStatus.self, forKey: .status)
    summary = try container.decode(String.self, forKey: .summary)
    remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
    rollbackReviewURL = try container.decodeIfPresent(String.self, forKey: .rollbackReviewURL)
    nextActions = try container.decodeIfPresent([String].self, forKey: .nextActions) ?? []
    commandLines = try container.decode([String].self, forKey: .commandLines)
    reviewTitle = try container.decodeIfPresent(String.self, forKey: .reviewTitle)
    reviewBody = try container.decodeIfPresent(String.self, forKey: .reviewBody)
    changedPaths = try container.decode([String].self, forKey: .changedPaths)
    clipboardMarkdown = try container.decode(String.self, forKey: .clipboardMarkdown)
  }
}

public extension ReleaseLedgerEntry {
  var recoveryPackage: ReleaseRecoveryPackage {
    let rollback = rollbackDraft
    let remoteURL = deploymentStatus?.diagnosticSignals
      .compactMap { $0.urlText?.trimmedForPublishing.nilIfEmpty }
      .first
      ?? deploymentStatus?.siteURLText?.trimmedForPublishing.nilIfEmpty
      ?? rollback?.remoteURL?.trimmedForPublishing.nilIfEmpty
      ?? record.reviewURL?.trimmedForPublishing.nilIfEmpty
    let commandLines = rollback?.commandLines ?? []
    let reviewTitle = rollback?.reviewTitle ?? record.reviewTitle
    let reviewBody = rollback?.reviewBody
    let rollbackReviewURL = rollback?.reviewURL?.trimmedForPublishing.nilIfEmpty
    let changedPaths = rollback?.changedPaths.isEmpty == false ? rollback?.changedPaths ?? [] : record.changedPaths
    let title = "发布恢复包：\(record.draftTitle ?? record.title)"
    let summary = rollback?.summary ?? statusMessage
    let nextActions = recoveryNextActions(
      remoteURL: remoteURL,
      rollbackReviewURL: rollbackReviewURL,
      commandLines: commandLines,
      changedPaths: changedPaths
    )
    return ReleaseRecoveryPackage(
      title: title,
      status: status,
      summary: summary,
      remoteURL: remoteURL,
      rollbackReviewURL: rollbackReviewURL,
      nextActions: nextActions,
      commandLines: commandLines,
      reviewTitle: reviewTitle,
      reviewBody: reviewBody,
      changedPaths: changedPaths,
      clipboardMarkdown: recoveryClipboardMarkdown(
        title: title,
        summary: summary,
        remoteURL: remoteURL,
        rollbackReviewURL: rollbackReviewURL,
        nextActions: nextActions,
        commandLines: commandLines,
        reviewTitle: reviewTitle,
        reviewBody: reviewBody,
        changedPaths: changedPaths
      )
    )
  }

  private func recoveryClipboardMarkdown(
    title: String,
    summary: String,
    remoteURL: String?,
    rollbackReviewURL: String?,
    nextActions: [String],
    commandLines: [String],
    reviewTitle: String?,
    reviewBody: String?,
    changedPaths: [String]
  ) -> String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = [
      "# \(title)",
      "",
      "- 状态：\(status.displayName)",
      "- 类型：\(record.kind.displayName)",
      "- 记录：\(record.title)",
      "- 时间：\(formatter.string(from: record.createdAt))",
      "- 结论：\(statusMessage)"
    ]

    if let siteName = record.siteName?.trimmedForPublishing.nilIfEmpty {
      lines.append("- 站点：\(siteName)")
    }
    if let markdownPath = record.markdownPath?.trimmedForPublishing.nilIfEmpty {
      lines.append("- 文章路径：\(markdownPath)")
    }
    if let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty {
      lines.append("- 分支：\(branchName)")
    }
    if let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty {
      lines.append("- 目标分支：\(targetBranch)")
    }
    if let commitSHA = record.commitSHA?.trimmedForPublishing.nilIfEmpty {
      lines.append("- Commit：\(commitSHA)")
    }
    if let remoteURL {
      lines.append("- 远端诊断：\(remoteURL)")
    }
    if let rollbackReviewURL {
      lines.append("- 回滚 PR/MR：\(rollbackReviewURL)")
    }

    if !record.batchItems.isEmpty {
      lines.append("")
      lines.append("## 批量文章明细")
      for item in record.batchItems {
        lines.append("- \(item.draftTitle)：\(item.markdownPath)")
        let extraPaths = item.changedPaths.filter { $0 != item.markdownPath }
        if !extraPaths.isEmpty {
          lines.append("  - 相关文件：\(extraPaths.joined(separator: "、"))")
        }
      }
    }

    if let deploymentStatus {
      lines.append(contentsOf: [
        "",
        "## 部署状态",
        "- \(deploymentStatus.title)：\(deploymentStatus.message)",
        "- 检查时间：\(formatter.string(from: deploymentStatus.checkedAt))"
      ])
      if let siteURLText = deploymentStatus.siteURLText?.trimmedForPublishing.nilIfEmpty {
        lines.append("- 站点 URL：\(siteURLText)")
      }
      lines.append("")
      lines.append("### 发布后校验清单")
      for item in deploymentStatus.postPublishCheckItems {
        lines.append("- [\(item.checklistMarker)] \(item.title)：\(item.message)")
        if let urlText = item.urlText?.trimmedForPublishing.nilIfEmpty {
          lines.append("  - \(urlText)")
        }
      }
      if !deploymentStatus.signals.isEmpty {
        lines.append("")
        lines.append("### 部署信号")
        for signal in deploymentStatus.signals {
          lines.append("- [\(signal.level.displayName)] \(signal.title)：\(signal.message)")
          if let urlText = signal.urlText?.trimmedForPublishing.nilIfEmpty {
            lines.append("  \(urlText)")
          }
        }
      }
    }

    if !changedPaths.isEmpty {
      lines.append("")
      lines.append("## 变更文件")
      lines.append(contentsOf: changedPaths.map { "- \($0)" })
    }

    if !nextActions.isEmpty {
      lines.append("")
      lines.append("## 下一步清单")
      lines.append(contentsOf: nextActions.map { "- [ ] \($0)" })
    }

    lines.append("")
    lines.append("## 恢复方案")
    lines.append(summary)
    if !commandLines.isEmpty {
      lines.append("")
      lines.append("```bash")
      lines.append(contentsOf: commandLines)
      lines.append("```")
    }

    if reviewTitle != nil || reviewBody != nil {
      lines.append("")
      lines.append("## 回滚 PR/MR 草稿")
      if let reviewTitle {
        lines.append("Title: \(reviewTitle)")
      }
      if let reviewBody {
        lines.append("")
        lines.append(reviewBody)
      }
    }

    return lines.joined(separator: "\n")
  }

  private func recoveryNextActions(
    remoteURL: String?,
    rollbackReviewURL: String?,
    commandLines: [String],
    changedPaths: [String]
  ) -> [String] {
    var actions: [String] = []

    switch status {
    case .pendingRemoteRecovery:
      if let commitSHA = record.commitSHA?.trimmedForPublishing.nilIfEmpty {
        actions.append("先确认远端 commit \(String(commitSHA.prefix(8))) 是否已经写入目标分支。")
      } else {
        actions.append("先确认远端分支或 Review 是否已经产生部分写入。")
      }
      if !changedPaths.isEmpty {
        actions.append("逐项核对恢复包中的变更文件，确认是否需要保留、重试或回滚。")
      }
      if remoteURL != nil {
        actions.append("打开远端诊断链接确认最新 Actions、Pipeline、commit 或分支状态。")
      }
      if rollbackReviewURL != nil || !commandLines.isEmpty {
        actions.append("如远端状态不可接受，使用回滚命令创建回滚分支并发起 PR/MR。")
      }
      actions.append("完成确认后重新执行部署检查，直到发布记录转为已上线或失败。")

    case .pendingRetry:
      if remoteURL != nil {
        actions.append("先打开远端诊断链接，确认网络或部署服务是否已恢复。")
      }
      actions.append("重新执行部署状态检查或等待自动轮询写入新快照。")
      actions.append("如果连续失败，把该记录升级为失败处理并保留恢复包。")

    case .failed:
      if remoteURL != nil {
        actions.append("先打开远端诊断链接定位失败的 Actions、Pipeline 或状态端点。")
      }
      actions.append("修复失败原因后重新执行部署检查。")
      if rollbackReviewURL != nil || !commandLines.isEmpty {
        actions.append("如果不准备继续修复，使用回滚命令和 PR/MR 草稿撤销本次发布。")
      }

    case .pendingDeployment, .deploying:
      if remoteURL != nil {
        actions.append("打开远端部署页面确认当前运行状态。")
      }
      actions.append("保持轮询或稍后手动刷新部署状态。")
      actions.append("部署完成后检查文章页面、Open Graph 和 Twitter 卡片校验项。")

    case .pendingReview:
      actions.append("先合并或关闭当前 PR/MR，再让发布记录进入部署检查或撤回状态。")
      if rollbackReviewURL != nil || !commandLines.isEmpty {
        actions.append("如果不再发布，使用恢复包里的撤回命令或关闭 Review 草稿。")
      }

    case .localOnly:
      actions.append("确认本地工作树只包含本次发布文件。")
      actions.append("继续提交本地变更，或使用恢复命令撤回本次写入。")

    case .succeeded:
      actions.append("保留回滚命令和 PR/MR 草稿，作为发布后事故恢复预案。")
      actions.append("如发现线上问题，先确认没有其他手动编辑混入这些路径。")

    case .unknown:
      actions.append("补充发布记录、远端链接或部署快照后再判断是否重试或回滚。")
    }

    return actions
  }
}

public extension ReleaseRecoveryPackage {
  var externalVerificationEvidenceMarkdown: String {
    [
      "Remote conflict preview: \(remoteConflictPreviewEvidence)",
      "Pending/offline state: \(pendingOfflineStateEvidence)",
      "Deployment retry: \(deploymentRetryEvidence)",
      "Rollback package: \(rollbackPackageEvidence)"
    ].joined(separator: "\n")
  }

  private var remoteConflictPreviewEvidence: String {
    let pathSummary = changedPaths.isEmpty
      ? "no changed paths were recorded"
      : changedPaths.prefix(4).joined(separator: ", ")
    return "Release ledger recovery package lists \(pathSummary) and keeps the remote diagnostic URL \(remoteURL ?? "unavailable") for manual conflict confirmation before retry or rollback."
  }

  private var pendingOfflineStateEvidence: String {
    "Release ledger status is \(status.displayName) and the recovery summary is: \(summary)"
  }

  private var deploymentRetryEvidence: String {
    if let remoteURL {
      return "Manual deployment retry/check should reopen \(remoteURL), then refresh the deployment status panel or polling queue."
    }
    return "Manual deployment retry/check should refresh the deployment status panel or polling queue after network or provider recovery."
  }

  private var rollbackPackageEvidence: String {
    var parts: [String] = []
    if !commandLines.isEmpty {
      parts.append("commands: \(commandLines.joined(separator: " ; "))")
    }
    if let rollbackReviewURL {
      parts.append("PR/MR draft: \(rollbackReviewURL)")
    }
    if let reviewTitle {
      parts.append("title: \(reviewTitle)")
    }
    if !changedPaths.isEmpty {
      parts.append("files: \(changedPaths.joined(separator: ", "))")
    }
    if parts.isEmpty {
      return "Recovery package has no rollback command; keep the release ledger entry for manual follow-up."
    }
    return "Recovery package includes " + parts.joined(separator: " | ")
  }
}

public struct ReleaseLedgerSummary: Codable, Hashable, Sendable {
  public var totalCount: Int
  public var actionItemCount: Int
  public var localPendingCount: Int
  public var reviewPendingCount: Int
  public var deploymentPendingCount: Int
  public var remoteRecoveryPendingCount: Int
  public var succeededCount: Int
  public var failedCount: Int
  public var rollbackAvailableCount: Int

  public init(
    totalCount: Int,
    actionItemCount: Int,
    localPendingCount: Int,
    reviewPendingCount: Int,
    deploymentPendingCount: Int,
    remoteRecoveryPendingCount: Int,
    succeededCount: Int,
    failedCount: Int,
    rollbackAvailableCount: Int
  ) {
    self.totalCount = totalCount
    self.actionItemCount = actionItemCount
    self.localPendingCount = localPendingCount
    self.reviewPendingCount = reviewPendingCount
    self.deploymentPendingCount = deploymentPendingCount
    self.remoteRecoveryPendingCount = remoteRecoveryPendingCount
    self.succeededCount = succeededCount
    self.failedCount = failedCount
    self.rollbackAvailableCount = rollbackAvailableCount
  }
}

public struct ReleaseLedger: Codable, Hashable, Sendable {
  public var summary: ReleaseLedgerSummary
  public var deploymentOverview: ReleaseDeploymentOverview
  public var actionItems: [ReleaseLedgerActionItem]
  public var entries: [ReleaseLedgerEntry]

  public init(
    summary: ReleaseLedgerSummary,
    deploymentOverview: ReleaseDeploymentOverview,
    actionItems: [ReleaseLedgerActionItem],
    entries: [ReleaseLedgerEntry]
  ) {
    self.summary = summary
    self.deploymentOverview = deploymentOverview
    self.actionItems = actionItems
    self.entries = entries
  }
}

public extension ReleaseLedger {
  var remoteRecoveryVerificationDraftMarkdown: String {
    let conflictEntry = representativeRemoteRecoveryEntry(
      preferredStatuses: [.pendingRemoteRecovery],
      fallbackStatuses: [.failed, .pendingRetry, .pendingDeployment, .unknown]
    )
    let pendingEntry = representativeRemoteRecoveryEntry(
      preferredStatuses: [.pendingRetry, .pendingRemoteRecovery],
      fallbackStatuses: [.unknown, .pendingDeployment, .failed]
    )
    let retryEntry = representativeRemoteRecoveryEntry(
      preferredStatuses: [.pendingRetry, .failed, .pendingDeployment, .deploying],
      fallbackStatuses: [.pendingRemoteRecovery, .unknown]
    )
    let rollbackEntry = entries.first { entry in
      entry.rollbackDraft != nil || !entry.recoveryPackage.commandLines.isEmpty
    } ?? conflictEntry ?? retryEntry ?? pendingEntry

    var lines: [String] = [
      "# 远端恢复外部验收草稿",
      "",
      "- 状态：草稿；需用一次真实 GitHub/GitLab 远端发布、部署检查和回滚演练补齐，不要直接当作完成证据。",
      "- 发布记录：\(summary.totalCount)",
      "- 远端待确认：\(summary.remoteRecoveryPendingCount)",
      "- 待处理：\(summary.actionItemCount)",
      "- 失败：\(summary.failedCount)",
      "",
      "## remote-recovery.env 填写草稿",
      "- REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY=\(remoteRecoveryEvidenceLine(from: conflictEntry, prefix: "Remote conflict preview:", fallback: "Remote conflict preview: 未找到远端冲突或部分发布记录；请用 disposable repo 触发一次远端冲突预览后补齐。"))",
      "- REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY=\(remoteRecoveryEvidenceLine(from: pendingEntry, prefix: "Pending/offline state:", fallback: "Pending/offline state: 未找到 pending/offline 记录；请断网或模拟状态端点失败后补齐。"))",
      "- REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY=\(remoteRecoveryEvidenceLine(from: retryEntry, prefix: "Deployment retry:", fallback: "Deployment retry: 未找到可重试部署记录；请完成一次失败或未知部署检查后补齐。"))",
      "- REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY=\(remoteRecoveryEvidenceLine(from: rollbackEntry, prefix: "Rollback package:", fallback: "Rollback package: 未找到回滚命令或 PR/MR 草稿；请用带 commit 的线上提交生成回滚包后补齐。"))",
      "",
      "## 代表记录"
    ]

    let representativeEntries = [conflictEntry, pendingEntry, retryEntry, rollbackEntry]
      .compactMap { $0 }
      .reduce(into: [ReleaseLedgerEntry]()) { result, entry in
        if !result.contains(where: { $0.id == entry.id }) {
          result.append(entry)
        }
      }

    if representativeEntries.isEmpty {
      lines.append("- 当前台账没有可用于远端恢复验收的记录。")
    } else {
      for entry in representativeEntries {
        lines.append(contentsOf: remoteRecoveryRepresentativeLines(for: entry))
      }
    }

    lines.append("")
    lines.append("## 使用方式")
    lines.append("- 先复制本草稿，执行一次真实外部验收后用实测结论替换上述四个 env 值。")
    lines.append("- 只有在四项都来自真实远端结果时，才运行 remote-recovery 外部验收脚本并记录证据。")

    return lines.joined(separator: "\n")
  }

  var operationLogMarkdown: String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = [
      "# 发布台账",
      "",
      "## 总览",
      "- 发布记录：\(summary.totalCount)",
      "- 待处理：\(summary.actionItemCount)",
      "- 本地待处理：\(summary.localPendingCount)",
      "- 等待合并：\(summary.reviewPendingCount)",
      "- 等待部署：\(summary.deploymentPendingCount)",
      "- 远端待确认：\(summary.remoteRecoveryPendingCount)",
      "- 已上线：\(summary.succeededCount)",
      "- 失败：\(summary.failedCount)",
      "- 可回滚：\(summary.rollbackAvailableCount)",
      "",
      "## 部署态势",
      "- 状态：\(deploymentOverview.title)",
      "- 说明：\(deploymentOverview.message)",
      "- 下一步：\(deploymentOverview.nextActionTitle) - \(deploymentOverview.nextActionMessage)",
      "- 已检查：\(deploymentOverview.checkedRecordCount)",
      "- 未检查：\(deploymentOverview.uncheckedDeploymentCount)",
      "- 运行中：\(deploymentOverview.runningDeploymentCount)",
      "- 失败：\(deploymentOverview.failedDeploymentCount)"
    ]

    if let lastCheckedAt = deploymentOverview.lastCheckedAt {
      lines.append("- 最近检查：\(formatter.string(from: lastCheckedAt))")
    }

    if !deploymentOverview.highlightedSignals.isEmpty {
      lines.append("")
      lines.append("### 重点部署信号")
      for signal in deploymentOverview.highlightedSignals {
        lines.append("- [\(signal.level.displayName)] \(signal.title)：\(signal.message)")
        if let urlText = signal.urlText?.trimmedForPublishing.nilIfEmpty {
          lines.append("  \(urlText)")
        }
      }
    }

    lines.append("")
    lines.append("## 行动队列")
    if actionItems.isEmpty {
      lines.append("- 当前没有需要处理的发布事项。")
    } else {
      for item in actionItems {
        lines.append("- [\(item.priority.displayName)] \(item.kind.displayName)：\(item.title)")
        lines.append("  - \(item.summary)")
        if !item.detail.isEmpty {
          lines.append("  - 详情：\(item.detail)")
        }
        if let remoteURL = item.remoteURL?.trimmedForPublishing.nilIfEmpty {
          lines.append("  - 远端：\(remoteURL)")
        }
        if !item.commandLines.isEmpty {
          lines.append("  - 命令：`\(item.commandLines.joined(separator: " && "))`")
        }
      }
    }

    lines.append("")
    lines.append("## 发布记录")
    if entries.isEmpty {
      lines.append("- 暂无发布记录。")
    } else {
      for entry in entries.prefix(20) {
        lines.append(contentsOf: operationLogLines(for: entry, formatter: formatter))
      }
      if entries.count > 20 {
        lines.append("- 还有 \(entries.count - 20) 条较早记录未展开。")
      }
    }

    return lines.joined(separator: "\n")
  }

  private func operationLogLines(
    for entry: ReleaseLedgerEntry,
    formatter: ISO8601DateFormatter
  ) -> [String] {
    let record = entry.record
    var lines: [String] = [
      "- \(record.title)",
      "  - 状态：\(entry.status.displayName)",
      "  - 类型：\(record.kind.displayName)",
      "  - 时间：\(formatter.string(from: record.createdAt))",
      "  - 说明：\(entry.statusMessage)"
    ]

    if let draftTitle = record.draftTitle?.trimmedForPublishing.nilIfEmpty {
      lines.append("  - 文章：\(draftTitle)")
    }
    if let markdownPath = record.markdownPath?.trimmedForPublishing.nilIfEmpty {
      lines.append("  - 路径：\(markdownPath)")
    }
    if let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty {
      lines.append("  - 分支：\(branchName)")
    }
    if let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty {
      lines.append("  - 目标分支：\(targetBranch)")
    }
    if let commitSHA = record.commitSHA?.trimmedForPublishing.nilIfEmpty {
      lines.append("  - Commit：\(commitSHA)")
    }
    if let reviewURL = record.reviewURL?.trimmedForPublishing.nilIfEmpty {
      lines.append("  - PR/MR：\(reviewURL)")
    }
    if !record.changedPaths.isEmpty {
      lines.append("  - 变更文件：\(record.changedPaths.prefix(8).joined(separator: "、"))")
    }
    if !record.batchItems.isEmpty {
      lines.append("  - 批量文章：\(record.batchItems.count)")
      for item in record.batchItems.prefix(5) {
        lines.append("    - \(item.draftTitle)：\(item.markdownPath)")
      }
    }
    if let deploymentStatus = entry.deploymentStatus {
      lines.append("  - 部署：\(deploymentStatus.title) - \(deploymentStatus.message)")
      if let siteURLText = deploymentStatus.siteURLText?.trimmedForPublishing.nilIfEmpty {
        lines.append("  - 站点：\(siteURLText)")
      }
    }
    if let rollbackDraft = entry.rollbackDraft {
      lines.append("  - 回滚：\(rollbackDraft.summary)")
      if let reviewURL = rollbackDraft.reviewURL?.trimmedForPublishing.nilIfEmpty {
        lines.append("  - 回滚 PR/MR：\(reviewURL)")
      }
    }

    return lines
  }

  private func representativeRemoteRecoveryEntry(
    preferredStatuses: [ReleaseLedgerStatus],
    fallbackStatuses: [ReleaseLedgerStatus]
  ) -> ReleaseLedgerEntry? {
    entries.first { preferredStatuses.contains($0.status) }
      ?? entries.first { entry in
        fallbackStatuses.contains(entry.status)
          || entry.rollbackDraft != nil
          || !entry.recoveryPackage.commandLines.isEmpty
      }
  }

  private func remoteRecoveryEvidenceLine(
    from entry: ReleaseLedgerEntry?,
    prefix: String,
    fallback: String
  ) -> String {
    guard let package = entry?.recoveryPackage else {
      return fallback
    }

    return package.externalVerificationEvidenceMarkdown
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .first { $0.hasPrefix(prefix) } ?? fallback
  }

  private func remoteRecoveryRepresentativeLines(for entry: ReleaseLedgerEntry) -> [String] {
    let package = entry.recoveryPackage
    var lines = [
      "- \(entry.record.title)",
      "  - 状态：\(entry.status.displayName)",
      "  - 说明：\(entry.statusMessage)"
    ]

    if let remoteURL = package.remoteURL?.trimmedForPublishing.nilIfEmpty {
      lines.append("  - 远端：\(remoteURL)")
    }
    if !package.changedPaths.isEmpty {
      lines.append("  - 变更文件：\(package.changedPaths.prefix(8).joined(separator: "、"))")
    }
    if !package.commandLines.isEmpty {
      lines.append("  - 回滚命令：`\(package.commandLines.joined(separator: " && "))`")
    }
    if let rollbackReviewURL = package.rollbackReviewURL?.trimmedForPublishing.nilIfEmpty {
      lines.append("  - 回滚 PR/MR：\(rollbackReviewURL)")
    }

    return lines
  }
}

public enum ReleaseLedgerActionPriority: Int, Codable, CaseIterable, Hashable, Sendable {
  case high
  case medium
  case low

  public var displayName: String {
    switch self {
    case .high:
      return "高"
    case .medium:
      return "中"
    case .low:
      return "低"
    }
  }
}

public enum ReleaseLedgerActionKind: String, Codable, Hashable, Sendable {
  case failedRelease
  case retryDeploymentCheck
  case observeDeployment
  case completeReview
  case publishLocalChanges
  case recoverPartialRemotePublish
  case keepRollbackReady

  public var displayName: String {
    switch self {
    case .failedRelease:
      return "失败处理"
    case .retryDeploymentCheck:
      return "重试检查"
    case .observeDeployment:
      return "部署观察"
    case .completeReview:
      return "合并 Review"
    case .publishLocalChanges:
      return "提交本地"
    case .recoverPartialRemotePublish:
      return "远端恢复"
    case .keepRollbackReady:
      return "回滚预案"
    }
  }
}

public extension ReleaseLedgerActionKind {
  var supportsDeploymentRecheck: Bool {
    switch self {
    case .failedRelease, .retryDeploymentCheck, .observeDeployment, .recoverPartialRemotePublish:
      return true
    case .completeReview, .publishLocalChanges, .keepRollbackReady:
      return false
    }
  }
}

public struct ReleaseLedgerActionItem: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var recordID: UUID
  public var kind: ReleaseLedgerActionKind
  public var priority: ReleaseLedgerActionPriority
  public var title: String
  public var summary: String
  public var detail: String
  public var systemImage: String
  public var remoteURL: String?
  public var commandLines: [String]
  public var createdAt: Date
}

public struct ReleaseDeploymentOverview: Codable, Hashable, Sendable {
  public var level: DeploymentStatusLevel
  public var title: String
  public var message: String
  public var checkedRecordCount: Int
  public var uncheckedDeploymentCount: Int
  public var failedDeploymentCount: Int
  public var runningDeploymentCount: Int
  public var lastCheckedAt: Date?
  public var nextActionTitle: String
  public var nextActionMessage: String
  public var highlightedSignals: [DeploymentStatusSignal]

  public init(
    level: DeploymentStatusLevel,
    title: String,
    message: String,
    checkedRecordCount: Int,
    uncheckedDeploymentCount: Int,
    failedDeploymentCount: Int,
    runningDeploymentCount: Int,
    lastCheckedAt: Date?,
    nextActionTitle: String,
    nextActionMessage: String,
    highlightedSignals: [DeploymentStatusSignal]
  ) {
    self.level = level
    self.title = title
    self.message = message
    self.checkedRecordCount = checkedRecordCount
    self.uncheckedDeploymentCount = uncheckedDeploymentCount
    self.failedDeploymentCount = failedDeploymentCount
    self.runningDeploymentCount = runningDeploymentCount
    self.lastCheckedAt = lastCheckedAt
    self.nextActionTitle = nextActionTitle
    self.nextActionMessage = nextActionMessage
    self.highlightedSignals = highlightedSignals
  }
}

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
      return "内容已经写入工作树，还没有形成可追踪的线上发布。"
    case .pendingReview:
      return record.reviewURL == nil
        ? "发布分支已经准备好，等待创建或合并 Review。"
        : "PR/MR 已准备，等待合并后进入部署。"
    case .pendingDeployment:
      return "提交已完成，尚未记录部署检查结果。"
    case .pendingRemoteRecovery:
      return "远端发布部分完成后中断；需要确认远端 commit、Review 或回滚方案。"
    case .pendingRetry:
      return deploymentStatus?.message ?? "部署检查暂时无法确认，稍后可重试。"
    case .deploying:
      return "部署仍在运行。"
    case .succeeded:
      return "部署检查已通过。"
    case .failed:
      return "发布或部署检查失败，需要处理后重试。"
    case .unknown:
      return "缺少足够信息判断发布状态。"
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
          title: "重试部署检查：\(entry.record.draftTitle ?? entry.record.title)",
          summary: entry.statusMessage,
          detail: entry.deploymentStatus?.title ?? "部署检查暂时不可确认。",
          systemImage: ReleaseLedgerStatus.pendingRetry.systemImage,
          remoteURL: diagnosticRemoteURL(for: entry),
          commandLines: []
        )
      case .pendingDeployment:
        return actionItem(
          entry: entry,
          kind: .observeDeployment,
          priority: .medium,
          title: "检查部署结果：\(entry.record.draftTitle ?? entry.record.title)",
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
          title: "继续观察部署：\(entry.record.draftTitle ?? entry.record.title)",
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
          title: "处理 Review：\(entry.record.draftTitle ?? entry.record.title)",
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
          title: "提交本地写入：\(entry.record.draftTitle ?? entry.record.title)",
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
          title: "保留回滚预案：\(entry.record.draftTitle ?? entry.record.title)",
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
    .prefix(12)
    .map { $0 }
  }

  private func failedReleaseAction(for entry: ReleaseLedgerEntry) -> ReleaseLedgerActionItem {
    let rollbackCommands = entry.rollbackDraft?.commandLines ?? []
    return actionItem(
      entry: entry,
      kind: .failedRelease,
      priority: .high,
      title: "处理失败发布：\(entry.record.draftTitle ?? entry.record.title)",
      summary: entry.statusMessage,
      detail: entry.deploymentStatus?.title ?? entry.record.summary,
      systemImage: ReleaseLedgerStatus.failed.systemImage,
      remoteURL: diagnosticRemoteURL(for: entry),
      commandLines: rollbackCommands
    )
  }

  private func partialRemoteRecoveryAction(for entry: ReleaseLedgerEntry) -> ReleaseLedgerActionItem {
    let rollbackCommands = entry.rollbackDraft?.commandLines ?? []
    let commitDetail = entry.record.shortCommitSHA.map { "远端 commit \($0) 已记录，先确认远端状态再决定重试或回滚。" }
      ?? "远端发布部分完成，先确认远端分支和变更路径。"
    return actionItem(
      entry: entry,
      kind: .recoverPartialRemotePublish,
      priority: .high,
      title: "确认远端部分发布：\(entry.record.draftTitle ?? entry.record.title)",
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
        title: "有远端恢复待确认",
        message: "\(pendingRemoteRecoveryCount) 条远端发布部分完成后中断，需要确认 commit、Review 或回滚方案。",
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: "确认远端恢复",
        nextActionMessage: "打开恢复包里的远端链接，确认已写入文件和 commit，再选择重试部署检查或发起回滚 PR/MR。",
        highlightedSignals: Array(highlightedSignals)
      )
    }

    if !failedSnapshots.isEmpty {
      return ReleaseDeploymentOverview(
        level: .failed,
        title: "有部署失败",
        message: "\(failedSnapshots.count) 条部署检查失败，需要查看失败信号后重试。",
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: "处理失败后重试",
        nextActionMessage: "打开失败记录的 Actions、Pipeline 或状态端点，修复后手动检查或等待轮询。",
        highlightedSignals: Array(highlightedSignals)
      )
    }

    if !runningSnapshots.isEmpty {
      return ReleaseDeploymentOverview(
        level: .running,
        title: "部署正在运行",
        message: "\(runningSnapshots.count) 条部署仍在运行，适合继续轮询。",
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: "继续观察部署",
        nextActionMessage: "保持轮询开启，或稍后手动刷新最新发布记录。",
        highlightedSignals: Array(highlightedSignals)
      )
    }

    if uncheckedDeploymentCount > 0 {
      return ReleaseDeploymentOverview(
        level: .unknown,
        title: "等待发布后校验",
        message: "\(uncheckedDeploymentCount) 条线上提交还没有部署检查结果。",
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: "检查待部署记录",
        nextActionMessage: "点击立即轮询或在最新发布记录上执行部署检查。",
        highlightedSignals: Array(highlightedSignals)
      )
    }

    if deploymentSnapshots.contains(where: { $0.level == .success }) {
      return ReleaseDeploymentOverview(
        level: .success,
        title: "发布后校验正常",
        message: "最近部署检查均未发现失败信号。",
        checkedRecordCount: deploymentSnapshots.count,
        uncheckedDeploymentCount: uncheckedDeploymentCount,
        failedDeploymentCount: failedSnapshots.count,
        runningDeploymentCount: runningSnapshots.count,
        lastCheckedAt: lastCheckedAt,
        nextActionTitle: "保持轮询",
        nextActionMessage: "继续保留轮询或在下次发布后自动检查。",
        highlightedSignals: Array(highlightedSignals)
      )
    }

    return ReleaseDeploymentOverview(
      level: .unknown,
      title: "还没有部署检查",
      message: "发布后可从记录中检查 GitHub Pages、GitLab Pipeline 或自定义状态端点。",
      checkedRecordCount: 0,
      uncheckedDeploymentCount: uncheckedDeploymentCount,
      failedDeploymentCount: 0,
      runningDeploymentCount: 0,
      lastCheckedAt: nil,
      nextActionTitle: "配置部署状态",
      nextActionMessage: "先配置仓库、站点 URL 或状态端点，再执行发布后校验。",
      highlightedSignals: []
    )
  }

  private func localRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    let paths = record.changedPaths.filter { !$0.trimmedForPublishing.isEmpty }
    guard !paths.isEmpty else {
      return nil
    }

    return ReleaseRollbackDraft(
      title: "恢复本地写入：\(record.draftTitle ?? record.title)",
      summary: "把本次写入的文件从工作树恢复到仓库当前版本。执行前先确认没有其他手动编辑混在这些路径里。",
      commandLines: [
        "git checkout -- \(paths.map(quotedShellPath).joined(separator: " "))"
      ],
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
    let reviewTitle = "Rollback: \(record.draftTitle ?? record.title)"
    let reviewBody = rollbackReviewBody(for: record, commitSHA: commitSHA, branchName: branchName)
    return ReleaseRollbackDraft(
      title: "回滚提交：\(record.draftTitle ?? record.title)",
      summary: "基于 \(branchName) 创建 \(rollbackBranchName)，生成 revert 提交来撤销 \(shortSHA)，再用下方回滚草稿发起 PR/MR。",
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
        title: "撤回 Review：\(record.draftTitle ?? record.title)",
        summary: "关闭或废弃这个 PR/MR；如果已经合并，应改用合并提交或目标分支上的 commit 做 revert。",
        commandLines: [
          "打开 Review 并关闭：\(reviewURL)"
        ],
        changedPaths: record.changedPaths,
        reviewTitle: "Close publishing review: \(record.draftTitle ?? record.title)",
        reviewBody: closeReviewBody(for: record),
        reviewURL: reviewURL,
        remoteURL: reviewURL
      )
    }

    guard let branchName = record.branchName?.trimmedForPublishing, !branchName.isEmpty else {
      return nil
    }

    return ReleaseRollbackDraft(
      title: "撤回发布分支：\(record.draftTitle ?? record.title)",
      summary: "删除尚未合并的发布分支。执行前确认该分支没有其他需要保留的提交。",
      commandLines: [
        "git push origin --delete \(quotedShellPath(branchName))"
      ],
      changedPaths: record.changedPaths,
      reviewBranchName: branchName,
      reviewTitle: "Close publishing branch: \(record.draftTitle ?? record.title)",
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
      ? "- 未记录变更路径"
      : record.changedPaths.map { "- \($0)" }.joined(separator: "\n")
    return """
    Reverts \(commitSHA) from \(branchName).

    Reason:
    - Roll back release record: \(record.title)
    - Status summary: \(record.summary)

    Changed paths:
    \(paths)

    Checklist:
    - [ ] Confirm this rollback does not remove unrelated manual edits.
    - [ ] Verify the site build and deployment after merge.
    """
  }

  private func closeReviewBody(for record: ReleaseRecord) -> String {
    let paths = record.changedPaths.isEmpty
      ? "- 未记录变更路径"
      : record.changedPaths.map { "- \($0)" }.joined(separator: "\n")
    return """
    This publishing review should be closed or superseded.

    Release record:
    - \(record.title)
    - \(record.summary)

    Changed paths:
    \(paths)

    Checklist:
    - [ ] Confirm the review branch has not already been merged.
    - [ ] If it was merged, create a revert commit against the target branch instead.
    """
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
