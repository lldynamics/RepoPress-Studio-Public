import Foundation
import PublishingWorkbenchCore
import SwiftUI

extension ReleaseHistoryDetailView {
  func releaseRecordCard(_ entry: ReleaseLedgerEntry) -> some View {
    let record = entry.record
    let deploymentStatus = entry.deploymentStatus
    let deploymentHistory = store.deploymentStatusHistory(for: record)
    let recoveryPackage = entry.recoveryPackage

    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Label(record.kind.localizedDisplayName, systemImage: record.kind.systemImage)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Label(entry.status.localizedDisplayName, systemImage: entry.status.systemImage)
          .font(.caption.weight(.medium))
          .foregroundStyle(ledgerStatusForeground(entry.status))
        Spacer()
        Text(record.createdAt.workbenchShortText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(record.title)
          .font(.headline)
        Text(record.summary)
          .foregroundStyle(.secondary)
        Text(entry.statusMessage)
          .font(.caption)
          .foregroundStyle(ledgerStatusForeground(entry.status))
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
        if let siteName = record.siteName {
          metadataRow("站点", siteName)
        }
        if let markdownPath = record.markdownPath {
          metadataRow("文章路径", markdownPath)
        }
        if let branchName = record.branchName {
          metadataRow("分支", branchName)
        }
        if let targetBranch = record.targetBranch {
          metadataRow("目标分支", targetBranch)
        }
        if let shortCommitSHA = record.shortCommitSHA {
          metadataRow("Commit", shortCommitSHA)
        }
        if let reviewTitle = record.reviewTitle {
          metadataRow("PR/MR 标题", reviewTitle)
        }
      }

      if !record.changedPaths.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("文件")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          ForEach(record.changedPaths, id: \.self) { path in
            Text(path)
              .font(.caption.monospaced())
              .lineLimit(1)
              .textSelection(.enabled)
          }
        }
      }

      if !record.batchItems.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("批量文章")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          ForEach(record.batchItems) { item in
            VStack(alignment: .leading, spacing: 2) {
              Text(item.draftTitle)
                .font(.caption.weight(.medium))
                .lineLimit(1)
              Text(item.markdownPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
              if item.changedPaths.count > 1 {
                Text("\(item.changedPaths.count) 个相关文件")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }
            }
          }
        }
      }

      if let deploymentStatus {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Label(deploymentStatus.title, systemImage: deploymentStatus.level.systemImage)
              .font(.callout.weight(.medium))
              .foregroundStyle(statusForeground(deploymentStatus.level))
            Spacer()
            Button {
              copy(deploymentStatus.clipboardSummary, message: "已复制部署诊断。")
            } label: {
              Label("复制诊断", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            Button {
              copy(deploymentStatus.postPublishChecklistMarkdown, message: "已复制发布后校验报告。")
            } label: {
              Label("复制报告", systemImage: "checklist.checked")
            }
            .controlSize(.small)
            if let siteURLText = deploymentStatus.siteURLText,
               let siteURL = URL(string: siteURLText) {
              Button {
                ExternalURLOpener.open(siteURL)
              } label: {
                Label("打开站点", systemImage: "safari")
              }
              .controlSize(.small)
            }
          }
          Text(deploymentStatus.message)
            .font(.caption)
            .foregroundStyle(.secondary)
          Label("\(deploymentStatus.nextActionTitle)：\(deploymentStatus.nextActionMessage)", systemImage: "checklist")
            .font(.caption)
            .foregroundStyle(statusForeground(deploymentStatus.level))

          if deploymentHistory.count > 1 {
            DeploymentStatusTrendChart(history: deploymentHistory)
            deploymentStatusHistoryTimeline(deploymentHistory)
          }

          deploymentPostPublishChecklist(deploymentStatus)

          ForEach(deploymentStatus.signals) { signal in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: signal.level.systemImage)
                .foregroundStyle(statusForeground(signal.level))
                .frame(width: 16)
              Text(signal.title)
                .font(.caption.weight(.medium))
              Text(signal.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
              Spacer()
              if let urlText = signal.urlText,
                 let url = URL(string: urlText) {
                Button {
                  ExternalURLOpener.open(url)
                } label: {
                  Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("打开部署信号")
                .accessibilityLabel("打开部署信号")
                .accessibilityValue(signal.title)
              }
            }
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }

      if !recoveryPackage.nextActions.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Label("恢复下一步", systemImage: "list.bullet.clipboard")
            .font(.callout.weight(.medium))

          ForEach(Array(recoveryPackage.nextActions.enumerated()), id: \.offset) { index, action in
            HStack(alignment: .top, spacing: 8) {
              Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
              Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }

      if let rollbackDraft = entry.rollbackDraft {
        VStack(alignment: .leading, spacing: 8) {
          Label("回滚计划", systemImage: "arrow.uturn.backward")
            .font(.callout.weight(.medium))
          Text(rollbackDraft.summary)
            .font(.caption)
            .foregroundStyle(.secondary)

          ForEach(rollbackDraft.commandLines, id: \.self) { command in
            Text(command)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .lineLimit(2)
          }

          if rollbackDraft.reviewTitle != nil || rollbackDraft.reviewBody != nil {
            VStack(alignment: .leading, spacing: 6) {
              Label("回滚 PR/MR 草稿", systemImage: "arrow.triangle.pull")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

              if let branchName = rollbackDraft.reviewBranchName {
                metadataTextRow("分支", branchName)
              }
              if let reviewTitle = rollbackDraft.reviewTitle {
                metadataTextRow("标题", reviewTitle)
              }
              if let reviewBody = rollbackDraft.reviewBody {
                Text(reviewBody)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                  .lineLimit(8)
              }
            }
            .padding(8)
            .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }

      HStack {
        Button {
          copyRecoveryPackage(recoveryPackage)
        } label: {
          Label("复制恢复包", systemImage: "shippingbox")
        }
        .accessibilityLabel("复制发布恢复包")

        Button {
          copyRecoveryEvidence(recoveryPackage)
        } label: {
          Label("复制验证摘要", systemImage: "checklist.checked")
        }
        .accessibilityLabel("复制发布恢复验证摘要")

        Button {
          Task {
            await store.sendReleaseRecoveryPackageToAI(for: entry)
          }
        } label: {
          Label("交给 AI", systemImage: "sparkles")
        }
        .disabled(record.draftID == nil || store.ai.isChatRunning)
        .accessibilityLabel("把发布恢复包交给 AI")

        if let commitSHA = record.commitSHA {
          Button {
            copy(commitSHA, message: "已复制 commit SHA。")
          } label: {
            Label("复制 Commit", systemImage: "number")
          }
          .accessibilityLabel("复制 Commit SHA")
          .accessibilityValue(commitSHA)
        }

        if let reviewURL = record.reviewURL {
          Button {
            copy(reviewURL, message: "已复制 PR/MR 链接。")
          } label: {
            Label("复制 PR/MR", systemImage: "doc.on.doc")
          }
          .accessibilityLabel("复制 PR 或 MR 链接")
          .accessibilityValue(reviewURL)
        }

        if let url = record.reviewWebURL {
          Button {
            ExternalURLOpener.open(url)
          } label: {
            Label("打开 PR/MR", systemImage: "arrow.up.right.square")
          }
          .accessibilityLabel("打开 PR 或 MR")
        }

        if hasReleaseRecordMoreActions(entry) {
          releaseRecordMoreMenu(entry)
        }

        Button {
          Task {
            await store.refreshDeploymentStatus(for: record)
          }
        } label: {
          Label("检查部署", systemImage: "checkmark.icloud")
        }
        .disabled(store.isDeploymentStatusChecking || !store.canCheckDeploymentStatus(for: record))
        .accessibilityLabel("检查部署状态")

        Spacer()
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  func releaseRecordMoreMenu(_ entry: ReleaseLedgerEntry) -> some View {
    let record = entry.record
    let rollbackDraft = entry.rollbackDraft

    return Menu {
      if let rollbackDraft {
        Button {
          copyRollbackDraft(rollbackDraft)
        } label: {
          Label("复制回滚计划", systemImage: "arrow.uturn.backward")
        }

        if rollbackDraft.reviewTitle != nil || rollbackDraft.reviewBody != nil {
          Button {
            copyRollbackReviewDraft(rollbackDraft)
          } label: {
            Label("复制回滚 PR/MR", systemImage: "arrow.triangle.pull")
          }
        }

        if let reviewURL = rollbackDraft.reviewURL.flatMap(URL.init(string:)) {
          Button {
            ExternalURLOpener.open(reviewURL)
          } label: {
            Label("打开回滚 PR/MR", systemImage: "arrow.triangle.pull")
          }
        }

        if let remoteURL = rollbackDraft.remoteURL.flatMap(URL.init(string:)) {
          Button {
            ExternalURLOpener.open(remoteURL)
          } label: {
            Label("打开远端回滚", systemImage: "arrow.up.right.square")
          }
        }
      }

      if rollbackDraft != nil && (canWithdrawRemoteReview(record) || canRollbackRemoteRelease(record)) {
        Divider()
      }

      if canWithdrawRemoteReview(record) {
        Button(role: .destructive) {
          pendingDangerousReleaseAction = .withdrawReview(record)
        } label: {
          Label("撤回线上 Review", systemImage: "arrow.down.forward.and.arrow.up.backward.circle")
        }
        .disabled(store.isRemoteRepositoryPublishing)
      }

      if canRollbackRemoteRelease(record) {
        Button(role: .destructive) {
          pendingDangerousReleaseAction = .rollbackRemote(record)
        } label: {
          Label("执行线上回滚", systemImage: "arrow.uturn.backward.circle")
        }
        .disabled(store.isRemoteRepositoryPublishing)
      }
    } label: {
      Label("更多...", systemImage: "ellipsis.circle")
    }
    .accessibilityLabel("更多发布记录操作")
  }

  func hasReleaseRecordMoreActions(_ entry: ReleaseLedgerEntry) -> Bool {
    entry.rollbackDraft != nil
      || canWithdrawRemoteReview(entry.record)
      || canRollbackRemoteRelease(entry.record)
  }

  func performDangerousReleaseAction(_ action: DangerousReleaseAction) async {
    switch action {
    case let .withdrawReview(record):
      await store.withdrawRemoteReview(record)
    case let .rollbackRemote(record):
      await store.rollbackRemoteRelease(record)
    }
  }

  func canRollbackRemoteRelease(_ record: ReleaseRecord) -> Bool {
    switch record.kind {
    case .remoteDirectCommit, .remotePublishFailure:
      return record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil
    case .localWrite, .batchLocalWrite, .directCommit, .reviewBranch, .remoteReviewRequest, .remoteRollback, .remoteReviewWithdrawal:
      return false
    }
  }

  func canWithdrawRemoteReview(_ record: ReleaseRecord) -> Bool {
    switch record.kind {
    case .remoteReviewRequest:
      return record.reviewURL?.trimmedForPublishing.nilIfEmpty != nil
    case .localWrite, .batchLocalWrite, .directCommit, .reviewBranch, .remoteDirectCommit, .remotePublishFailure, .remoteRollback, .remoteReviewWithdrawal:
      return false
    }
  }

}
