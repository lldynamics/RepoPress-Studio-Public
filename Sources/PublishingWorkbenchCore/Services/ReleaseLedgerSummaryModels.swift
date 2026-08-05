import Foundation

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
      CoreL10n.text("# 远端恢复外部验收草稿"),
      "",
      CoreL10n.text("- 状态：草稿；需用一次真实 GitHub/GitLab 远端发布、部署检查和回滚演练补齐，不要直接当作完成证据。"),
      CoreL10n.format("- 发布记录：%@", String(summary.totalCount)),
      CoreL10n.format("- 远端待确认：%@", String(summary.remoteRecoveryPendingCount)),
      CoreL10n.format("- 待处理：%@", String(summary.actionItemCount)),
      CoreL10n.format("- 失败：%@", String(summary.failedCount)),
      "",
      CoreL10n.text("## remote-recovery.env 填写草稿"),
      "- REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY=\(remoteRecoveryEvidenceLine(from: conflictEntry, prefix: "Remote conflict preview:", fallback: CoreL10n.text("Remote conflict preview: 未找到远端冲突或部分发布记录；请用 disposable repo 触发一次远端冲突预览后补齐。")))",
      "- REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY=\(remoteRecoveryEvidenceLine(from: pendingEntry, prefix: "Pending/offline state:", fallback: CoreL10n.text("Pending/offline state: 未找到 pending/offline 记录；请断网或模拟状态端点失败后补齐。")))",
      "- REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY=\(remoteRecoveryEvidenceLine(from: retryEntry, prefix: "Deployment retry:", fallback: CoreL10n.text("Deployment retry: 未找到可重试部署记录；请完成一次失败或未知部署检查后补齐。")))",
      "- REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY=\(remoteRecoveryEvidenceLine(from: rollbackEntry, prefix: "Rollback package:", fallback: CoreL10n.text("Rollback package: 未找到回滚命令或 PR/MR 草稿；请用带 commit 的线上提交生成回滚包后补齐。")))",
      "",
      CoreL10n.text("## 代表记录")
    ]

    let representativeEntries = [conflictEntry, pendingEntry, retryEntry, rollbackEntry]
      .compactMap { $0 }
      .reduce(into: [ReleaseLedgerEntry]()) { result, entry in
        if !result.contains(where: { $0.id == entry.id }) {
          result.append(entry)
        }
      }

    if representativeEntries.isEmpty {
      lines.append(CoreL10n.text("- 当前台账没有可用于远端恢复验收的记录。"))
    } else {
      for entry in representativeEntries {
        lines.append(contentsOf: remoteRecoveryRepresentativeLines(for: entry))
      }
    }

    lines.append("")
    lines.append(CoreL10n.text("## 使用方式"))
    lines.append(CoreL10n.text("- 先复制本草稿，执行一次真实外部验收后用实测结论替换上述四个 env 值。"))
    lines.append(CoreL10n.text("- 只有在四项都来自真实远端结果时，才运行 remote-recovery 外部验收脚本并记录证据。"))

    return lines.joined(separator: "\n")
  }

  var operationLogMarkdown: String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = [
      CoreL10n.text("# 发布台账"),
      "",
      CoreL10n.text("## 总览"),
      CoreL10n.format("- 发布记录：%@", String(summary.totalCount)),
      CoreL10n.format("- 待处理：%@", String(summary.actionItemCount)),
      CoreL10n.format("- 本地待处理：%@", String(summary.localPendingCount)),
      CoreL10n.format("- 等待合并：%@", String(summary.reviewPendingCount)),
      CoreL10n.format("- 等待部署：%@", String(summary.deploymentPendingCount)),
      CoreL10n.format("- 远端待确认：%@", String(summary.remoteRecoveryPendingCount)),
      CoreL10n.format("- 已上线：%@", String(summary.succeededCount)),
      CoreL10n.format("- 失败：%@", String(summary.failedCount)),
      CoreL10n.format("- 可回滚：%@", String(summary.rollbackAvailableCount)),
      "",
      CoreL10n.text("## 部署态势"),
      CoreL10n.format("- 状态：%@", deploymentOverview.title),
      CoreL10n.format("- 说明：%@", deploymentOverview.message),
      CoreL10n.format("- 下一步：%@ - %@", deploymentOverview.nextActionTitle, deploymentOverview.nextActionMessage),
      CoreL10n.format("- 已检查：%@", String(deploymentOverview.checkedRecordCount)),
      CoreL10n.format("- 未检查：%@", String(deploymentOverview.uncheckedDeploymentCount)),
      CoreL10n.format("- 运行中：%@", String(deploymentOverview.runningDeploymentCount)),
      CoreL10n.format("- 失败：%@", String(deploymentOverview.failedDeploymentCount))
    ]

    if let lastCheckedAt = deploymentOverview.lastCheckedAt {
      lines.append(CoreL10n.format("- 最近检查：%@", formatter.string(from: lastCheckedAt)))
    }

    if !deploymentOverview.highlightedSignals.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("### 重点部署信号"))
      for signal in deploymentOverview.highlightedSignals {
        lines.append(CoreL10n.format("- [%@] %@：%@", signal.level.displayName, signal.title, signal.message))
        if let urlText = signal.urlText?.trimmedForPublishing.nilIfEmpty {
          lines.append("  \(urlText)")
        }
      }
    }

    lines.append("")
    lines.append(CoreL10n.text("## 行动队列"))
    if actionItems.isEmpty {
      lines.append(CoreL10n.text("- 当前没有需要处理的发布事项。"))
    } else {
      for item in actionItems {
        lines.append(CoreL10n.format("- [%@] %@：%@", item.priority.displayName, item.kind.displayName, item.title))
        lines.append("  - \(item.summary)")
        if !item.detail.isEmpty {
          lines.append(CoreL10n.format("  - 详情：%@", item.detail))
        }
        if let remoteURL = item.remoteURL?.trimmedForPublishing.nilIfEmpty {
          lines.append(CoreL10n.format("  - 远端：%@", remoteURL))
        }
        if !item.commandLines.isEmpty {
          lines.append(CoreL10n.format("  - 命令：`%@`", item.commandLines.joined(separator: " && ")))
        }
      }
    }

    lines.append("")
    lines.append(CoreL10n.text("## 发布记录"))
    if entries.isEmpty {
      lines.append(CoreL10n.text("- 暂无发布记录。"))
    } else {
      for entry in entries.prefix(20) {
        lines.append(contentsOf: operationLogLines(for: entry, formatter: formatter))
      }
      if entries.count > 20 {
        lines.append(CoreL10n.format("- 还有 %@ 条较早记录未展开。", String(entries.count - 20)))
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
      CoreL10n.format("  - 状态：%@", entry.status.displayName),
      CoreL10n.format("  - 类型：%@", record.kind.displayName),
      CoreL10n.format("  - 时间：%@", formatter.string(from: record.createdAt)),
      CoreL10n.format("  - 说明：%@", entry.statusMessage)
    ]

    if let draftTitle = record.draftTitle?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("  - 文章：%@", draftTitle))
    }
    if let markdownPath = record.markdownPath?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("  - 路径：%@", markdownPath))
    }
    if let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("  - 分支：%@", branchName))
    }
    if let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("  - 目标分支：%@", targetBranch))
    }
    if let commitSHA = record.commitSHA?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("  - Commit：%@", commitSHA))
    }
    if let reviewURL = record.reviewURL?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("  - PR/MR：%@", reviewURL))
    }
    if !record.changedPaths.isEmpty {
      lines.append(CoreL10n.format("  - 变更文件：%@", record.changedPaths.prefix(8).joined(separator: CoreL10n.text("、"))))
    }
    if !record.batchItems.isEmpty {
      lines.append(CoreL10n.format("  - 批量文章：%@", String(record.batchItems.count)))
      for item in record.batchItems.prefix(5) {
        lines.append(CoreL10n.format("    - %@：%@", item.draftTitle, item.markdownPath))
      }
    }
    if let deploymentStatus = entry.deploymentStatus {
      lines.append(CoreL10n.format("  - 部署：%@ - %@", deploymentStatus.title, deploymentStatus.message))
      if let siteURLText = deploymentStatus.siteURLText?.trimmedForPublishing.nilIfEmpty {
        lines.append(CoreL10n.format("  - 站点：%@", siteURLText))
      }
    }
    if let rollbackDraft = entry.rollbackDraft {
      lines.append(CoreL10n.format("  - 回滚：%@", rollbackDraft.summary))
      if let reviewURL = rollbackDraft.reviewURL?.trimmedForPublishing.nilIfEmpty {
        lines.append(CoreL10n.format("  - 回滚 PR/MR：%@", reviewURL))
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
      CoreL10n.format("  - 状态：%@", entry.status.displayName),
      CoreL10n.format("  - 说明：%@", entry.statusMessage)
    ]

    if let remoteURL = package.remoteURL?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("  - 远端：%@", remoteURL))
    }
    if !package.changedPaths.isEmpty {
      lines.append(CoreL10n.format("  - 变更文件：%@", package.changedPaths.prefix(8).joined(separator: CoreL10n.text("、"))))
    }
    if !package.commandLines.isEmpty {
      lines.append(CoreL10n.format("  - 回滚命令：`%@`", package.commandLines.joined(separator: " && ")))
    }
    if let rollbackReviewURL = package.rollbackReviewURL?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("  - 回滚 PR/MR：%@", rollbackReviewURL))
    }

    return lines
  }
}
