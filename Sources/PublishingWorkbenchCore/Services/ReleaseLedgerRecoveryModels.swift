import Foundation

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
    let title = CoreL10n.format("发布恢复包：%@", record.draftTitle ?? record.title)
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
      CoreL10n.format("- 状态：%@", status.displayName),
      CoreL10n.format("- 类型：%@", record.kind.displayName),
      CoreL10n.format("- 记录：%@", record.title),
      CoreL10n.format("- 时间：%@", formatter.string(from: record.createdAt)),
      CoreL10n.format("- 结论：%@", statusMessage)
    ]

    if let siteName = record.siteName?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- 站点：%@", siteName))
    }
    if let markdownPath = record.markdownPath?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- 文章路径：%@", markdownPath))
    }
    if let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- 分支：%@", branchName))
    }
    if let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- 目标分支：%@", targetBranch))
    }
    if let commitSHA = record.commitSHA?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- Commit：%@", commitSHA))
    }
    if let remoteURL {
      lines.append(CoreL10n.format("- 远端诊断：%@", remoteURL))
    }
    if let rollbackReviewURL {
      lines.append(CoreL10n.format("- 回滚 PR/MR：%@", rollbackReviewURL))
    }

    if !record.batchItems.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 批量文章明细"))
      for item in record.batchItems {
        lines.append(CoreL10n.format("- %@：%@", item.draftTitle, item.markdownPath))
        let extraPaths = item.changedPaths.filter { $0 != item.markdownPath }
        if !extraPaths.isEmpty {
          lines.append(CoreL10n.format("  - 相关文件：%@", extraPaths.joined(separator: CoreL10n.text("、"))))
        }
      }
    }

    if let deploymentStatus {
      lines.append(contentsOf: [
        "",
        CoreL10n.text("## 部署状态"),
        CoreL10n.format("- %@：%@", deploymentStatus.title, deploymentStatus.message),
        CoreL10n.format("- 检查时间：%@", formatter.string(from: deploymentStatus.checkedAt))
      ])
      if let siteURLText = deploymentStatus.siteURLText?.trimmedForPublishing.nilIfEmpty {
        lines.append(CoreL10n.format("- 站点 URL：%@", siteURLText))
      }
      lines.append("")
      lines.append(CoreL10n.text("### 发布后校验清单"))
      for item in deploymentStatus.postPublishCheckItems {
        lines.append(CoreL10n.format("- [%@] %@：%@", item.checklistMarker, item.title, item.message))
        if let urlText = item.urlText?.trimmedForPublishing.nilIfEmpty {
          lines.append("  - \(urlText)")
        }
      }
      if !deploymentStatus.signals.isEmpty {
        lines.append("")
        lines.append(CoreL10n.text("### 部署信号"))
        for signal in deploymentStatus.signals {
          lines.append(CoreL10n.format("- [%@] %@：%@", signal.level.displayName, signal.title, signal.message))
          if let urlText = signal.urlText?.trimmedForPublishing.nilIfEmpty {
            lines.append("  \(urlText)")
          }
        }
      }
    }

    if !changedPaths.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 变更文件"))
      lines.append(contentsOf: changedPaths.map { "- \($0)" })
    }

    if !nextActions.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 下一步清单"))
      lines.append(contentsOf: nextActions.map { "- [ ] \($0)" })
    }

    lines.append("")
    lines.append(CoreL10n.text("## 恢复方案"))
    lines.append(summary)
    if !commandLines.isEmpty {
      lines.append("")
      lines.append("```bash")
      lines.append(contentsOf: commandLines)
      lines.append("```")
    }

    if reviewTitle != nil || reviewBody != nil {
      lines.append("")
      lines.append(CoreL10n.text("## 回滚 PR/MR 草稿"))
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
        actions.append(CoreL10n.format("先确认远端 commit %@ 是否已经写入目标分支。", String(commitSHA.prefix(8))))
      } else {
        actions.append(CoreL10n.text("先确认远端分支或 Review 是否已经产生部分写入。"))
      }
      if !changedPaths.isEmpty {
        actions.append(CoreL10n.text("逐项核对恢复包中的变更文件，确认是否需要保留、重试或回滚。"))
      }
      if remoteURL != nil {
        actions.append(CoreL10n.text("打开远端诊断链接确认最新 Actions、Pipeline、commit 或分支状态。"))
      }
      if rollbackReviewURL != nil || !commandLines.isEmpty {
        actions.append(CoreL10n.text("如远端状态不可接受，使用回滚命令创建回滚分支并发起 PR/MR。"))
      }
      actions.append(CoreL10n.text("完成确认后重新执行部署检查，直到发布记录转为已上线或失败。"))

    case .pendingRetry:
      if remoteURL != nil {
        actions.append(CoreL10n.text("先打开远端诊断链接，确认网络或部署服务是否已恢复。"))
      }
      actions.append(CoreL10n.text("重新执行部署状态检查或等待自动轮询写入新快照。"))
      actions.append(CoreL10n.text("如果连续失败，把该记录升级为失败处理并保留恢复包。"))

    case .failed:
      if remoteURL != nil {
        actions.append(CoreL10n.text("先打开远端诊断链接定位失败的 Actions、Pipeline 或状态端点。"))
      }
      actions.append(CoreL10n.text("修复失败原因后重新执行部署检查。"))
      if rollbackReviewURL != nil || !commandLines.isEmpty {
        actions.append(CoreL10n.text("如果不准备继续修复，使用回滚命令和 PR/MR 草稿撤销本次发布。"))
      }

    case .pendingDeployment, .deploying:
      if remoteURL != nil {
        actions.append(CoreL10n.text("打开远端部署页面确认当前运行状态。"))
      }
      actions.append(CoreL10n.text("保持轮询或稍后手动刷新部署状态。"))
      actions.append(CoreL10n.text("部署完成后检查文章页面、Open Graph 和 Twitter 卡片校验项。"))

    case .pendingReview:
      actions.append(CoreL10n.text("先合并或关闭当前 PR/MR，再让发布记录进入部署检查或撤回状态。"))
      if rollbackReviewURL != nil || !commandLines.isEmpty {
        actions.append(CoreL10n.text("如果不再发布，使用恢复包里的撤回命令或关闭 Review 草稿。"))
      }

    case .reviewWithdrawn:
      actions.append(CoreL10n.text("该 PR/MR 已撤回，尚未合并到目标分支，也没有部署结果。"))

    case .previewOnly:
      actions.append(CoreL10n.text("该分支仅用于预览；需要正式发布时，请重新核对并选择直接提交或 PR/MR。"))

    case .localOnly:
      actions.append(CoreL10n.text("确认本地工作树只包含本次发布文件。"))
      actions.append(CoreL10n.text("继续提交本地变更，或使用恢复命令撤回本次写入。"))

    case .succeeded:
      actions.append(CoreL10n.text("保留回滚命令和 PR/MR 草稿，作为发布后事故恢复预案。"))
      actions.append(CoreL10n.text("如发现线上问题，先确认没有其他手动编辑混入这些路径。"))

    case .unknown:
      actions.append(CoreL10n.text("补充发布记录、远端链接或部署快照后再判断是否重试或回滚。"))
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
