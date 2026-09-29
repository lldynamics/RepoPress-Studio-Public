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
}
