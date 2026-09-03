import Foundation
import PublishingWorkbenchCore
import SwiftUI

extension ReleaseHistoryDetailView {
  func releaseRecordCard(_ entry: ReleaseLedgerEntry) -> some View {
    let record = entry.record

    return releaseRecordCardDetails(entry)
      .padding(14)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("发布记录：\(record.title)")
      .accessibilityValue(
        "\(entry.status.localizedDisplayName)，\(record.createdAt.workbenchShortText)"
      )
      .accessibilityIdentifier("release-record-\(record.id)")
  }

  private func releaseRecordCardDetails(_ entry: ReleaseLedgerEntry) -> some View {
    let record = entry.record
    let deploymentStatus = entry.deploymentStatus
    let deploymentHistory = store.deploymentStatusHistory(for: record)
    let recoveryPackage = entry.recoveryPackage

    return VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          releaseRecordStatusBadges(entry)
          Spacer(minLength: 10)
          releaseRecordTimestamp(record)
        }

        VStack(alignment: .leading, spacing: 6) {
          releaseRecordStatusBadges(entry)
          releaseRecordTimestamp(record)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(record.title)
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Text(record.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
        Text(entry.statusMessage)
          .font(.callout)
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
          metadataRow(
            record.kind == .remoteReviewRequest ? "Review Commit" : "Commit",
            shortCommitSHA
          )
        }
        if let reviewTitle = record.reviewTitle {
          metadataRow("PR/MR 标题", reviewTitle)
        }
        if let reviewStatus = record.reviewStatus {
          metadataRow("PR/MR 状态", reviewStatus.state.localizedDisplayName)
          if let mergeCommitSHA = reviewStatus.mergeCommitSHA?.trimmedForPublishing.nilIfEmpty {
            metadataRow("合并 Commit", String(mergeCommitSHA.prefix(8)))
          }
          if record.hasUnconfirmedReviewHeadDrift {
            metadataRow("部署归因", "已检测到新的 Review Commit，需手动确认")
          }
        }
      }

      if !record.changedPaths.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("文件")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
          ForEach(record.changedPaths, id: \.self) { path in
            WorkbenchPathIdentity(path: path)
          }
        }
      }

      if !record.batchItems.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("批量文章")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
          ForEach(record.batchItems) { item in
            VStack(alignment: .leading, spacing: 2) {
              Text(item.draftTitle)
                .font(.caption.weight(.medium))
                .workbenchTruncatedIdentity(item.draftTitle)
              Text(item.markdownPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .workbenchTruncatedIdentity(item.markdownPath)
              if item.changedPaths.count > 1 {
                Text("\(item.changedPaths.count) 个相关文件")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      if let deploymentStatus {
        VStack(alignment: .leading, spacing: 8) {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              deploymentStatusTitle(deploymentStatus)
              Spacer(minLength: 10)
              deploymentStatusActions(deploymentStatus, record: record)
            }

            VStack(alignment: .leading, spacing: 10) {
              deploymentStatusTitle(deploymentStatus)
              deploymentStatusActions(deploymentStatus, record: record)
            }
          }
          Text(deploymentStatus.message)
            .font(.callout)
            .foregroundStyle(.secondary)
          Label(
            "\(deploymentStatus.nextActionTitle)：\(deploymentStatus.nextActionMessage)",
            systemImage: "checklist"
          )
          .font(.callout)
          .foregroundStyle(statusForeground(deploymentStatus.level))

          if deploymentHistory.count > 1 {
            DeploymentStatusTrendChart(history: deploymentHistory)
            deploymentStatusHistoryTimeline(deploymentHistory)
          }

          deploymentPostPublishChecklist(deploymentStatus)

          ForEach(deploymentStatus.signals) { signal in
            VStack(alignment: .leading, spacing: 8) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: signal.level.systemImage)
                  .foregroundStyle(statusForeground(signal.level))
                  .frame(width: 16)
                Text(signal.title)
                  .font(.callout.weight(.medium))
                Text(signal.message)
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let urlText = signal.urlText,
                  let url = URL(string: urlText)
                {
                  Button {
                    ExternalURLOpener.open(url)
                  } label: {
                    Label("打开信号", systemImage: "arrow.up.right.square")
                  }
                  .buttonStyle(.bordered)
                  .help("打开部署信号")
                  .accessibilityLabel("打开部署信号")
                  .accessibilityValue(signal.title)
                  .accessibilityIdentifier("release-record-\(record.id)-open-signal-\(signal.id)")
                }
              }

              if !signal.logExcerpt.isEmpty {
                deploymentLogExcerpt(signal.logExcerpt)
              }
            }
          }
        }
        .padding(10)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(10)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }

      if let rollbackDraft = entry.rollbackDraft {
        VStack(alignment: .leading, spacing: 8) {
          Label("回滚计划", systemImage: "arrow.uturn.backward")
            .font(.callout.weight(.medium))
          Text(rollbackDraft.summary)
            .font(.callout)
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
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

              if let branchName = rollbackDraft.reviewBranchName {
                metadataTextRow("分支", branchName)
              }
              if let reviewTitle = rollbackDraft.reviewTitle {
                metadataTextRow("标题", reviewTitle)
              }
              if let reviewBody = rollbackDraft.reviewBody {
                Text(reviewBody)
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                  .lineLimit(8)
              }
            }
            .padding(8)
            .background(
              WorkbenchBackgroundStyle.card,
              in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
          }
        }
        .padding(10)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }

      releaseRecordActions(entry)
    }
  }

  private func deploymentLogExcerpt(_ entries: [DeploymentLogEntry]) -> some View {
    let orderedEntries = entries.sorted { lhs, rhs in
      deploymentLogPriority(lhs.level) > deploymentLogPriority(rhs.level)
    }
    let primaryFailure = orderedEntries.first(where: { $0.level == .error })

    return VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Label("构建日志摘录", systemImage: "doc.text.magnifyingglass")
          .font(.caption.weight(.semibold))
        Text("\(orderedEntries.count) 条")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if let primaryFailure {
          Text("首条失败：\(primaryFailure.message)")
            .font(.caption.monospaced())
            .foregroundStyle(WorkbenchTheme.risk)
            .lineLimit(2)
            .textSelection(.enabled)
        }
        Spacer(minLength: 0)
      }

      ForEach(orderedEntries) { entry in
        HStack(alignment: .top, spacing: 7) {
          Image(systemName: entry.level.systemImage)
            .foregroundStyle(deploymentLogForeground(entry.level))
            .frame(width: 15)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(entry.source)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
              if let stepName = entry.stepName?.nilIfEmpty {
                Text(stepName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .workbenchTruncatedIdentity(stepName)
              }
              if let locationText = entry.locationText {
                Text(locationText)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .workbenchTruncatedIdentity(locationText)
              }
            }
            Text(entry.message)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .lineLimit(12)
          }
          Spacer(minLength: 0)
        }
      }
    }
    .accessibilityIdentifier("release-deployment-log-excerpt")
  }

  private func deploymentLogPriority(_ level: DeploymentLogLevel) -> Int {
    switch level {
    case .error:
      return 3
    case .warning:
      return 2
    case .info:
      return 1
    }
  }

  private func deploymentLogForeground(_ level: DeploymentLogLevel) -> Color {
    switch level {
    case .error:
      return WorkbenchTheme.risk
    case .warning:
      return WorkbenchTheme.warning
    case .info:
      return .secondary
    }
  }

  private func releaseRecordStatusBadges(_ entry: ReleaseLedgerEntry) -> some View {
    HStack(spacing: 10) {
      Label(entry.record.kind.localizedDisplayName, systemImage: entry.record.kind.systemImage)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      Label(entry.status.localizedDisplayName, systemImage: entry.status.systemImage)
        .font(.caption.weight(.medium))
        .foregroundStyle(ledgerStatusForeground(entry.status))
    }
  }

  private func releaseRecordTimestamp(_ record: ReleaseRecord) -> some View {
    Text(record.createdAt.workbenchShortText)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func deploymentStatusTitle(_ deploymentStatus: DeploymentStatusSnapshot) -> some View {
    Label(deploymentStatus.title, systemImage: deploymentStatus.level.systemImage)
      .font(.callout.weight(.medium))
      .foregroundStyle(statusForeground(deploymentStatus.level))
      .fixedSize(horizontal: false, vertical: true)
  }

  private func deploymentStatusActions(
    _ deploymentStatus: DeploymentStatusSnapshot,
    record: ReleaseRecord
  ) -> some View {
    HStack(spacing: 8) {
      Button {
        copy(deploymentStatus.clipboardSummary, message: "已复制部署诊断。")
      } label: {
        Label("复制诊断", systemImage: "doc.on.doc")
      }
      .accessibilityIdentifier("release-record-\(record.id)-copy-diagnostics")

      if let siteURLText = deploymentStatus.siteURLText,
        let siteURL = URL(string: siteURLText)
      {
        Button {
          ExternalURLOpener.open(siteURL)
        } label: {
          Label("打开站点", systemImage: "safari")
        }
        .accessibilityIdentifier("release-record-\(record.id)-open-site")
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
    .accessibilityElement(children: .contain)
  }

  func releaseRecordActions(_ entry: ReleaseLedgerEntry) -> some View {
    let record = entry.record
    let rollbackDraft = entry.rollbackDraft

    return VStack(alignment: .leading, spacing: 10) {
      Label("记录操作", systemImage: "slider.horizontal.3")
        .font(.callout.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 8)],
        alignment: .leading,
        spacing: 8
      ) {
        Button {
          copyRecoveryPackage(entry.recoveryPackage)
        } label: {
          releaseRecordActionLabel("复制恢复包", systemImage: "shippingbox")
        }
        .accessibilityLabel("复制发布恢复包")
        .accessibilityIdentifier("release-record-\(record.id)-copy-recovery")

        Button {
          Task {
            await store.refreshDeploymentStatus(for: record)
          }
        } label: {
          releaseRecordActionLabel("检查部署", systemImage: "checkmark.icloud")
        }
        .disabled(store.isDeploymentStatusChecking || !store.canCheckDeploymentStatus(for: record))
        .accessibilityLabel("检查部署状态")
        .accessibilityIdentifier("release-record-\(record.id)-check-deployment")

        if record.kind == .remoteReviewRequest,
          record.reviewStatus?.state != .merged
        {
          Button {
            Task {
              await store.refreshRemoteReviewStatus(for: record)
            }
          } label: {
            releaseRecordActionLabel("检查 PR/MR", systemImage: "arrow.triangle.pull")
          }
          .disabled(store.isDeploymentStatusChecking)
          .accessibilityLabel("检查 PR/MR 合并状态")
          .accessibilityIdentifier("release-record-\(record.id)-check-review")
        }

        if record.hasUnconfirmedReviewHeadDrift {
          Button {
            _ = store.acceptObservedReviewHead(for: record)
          } label: {
            releaseRecordActionLabel("确认新的 Review Commit", systemImage: "checkmark.shield")
          }
          .accessibilityLabel("确认新的 PR/MR head commit 后允许部署归因")
          .accessibilityIdentifier("release-record-\(record.id)-accept-review-head")
        }

        Button {
          Task {
            await store.sendReleaseRecoveryPackageToAI(for: entry)
          }
        } label: {
          releaseRecordActionLabel("交给 AI", systemImage: "sparkles")
        }
        .disabled(record.draftID == nil || store.ai.isChatRunning)
        .accessibilityIdentifier("release-record-\(record.id)-send-to-ai")

        PreviewPromotionEntryButton(store: store, record: record)

        if let commitSHA = record.deploymentCommitSHA ?? record.commitSHA {
          Button {
            copy(commitSHA, message: "已复制 commit SHA。")
          } label: {
            releaseRecordActionLabel(
              record.deploymentCommitSHA == nil ? "复制 Commit" : "复制部署 Commit",
              systemImage: "number"
            )
          }
          .accessibilityIdentifier("release-record-\(record.id)-copy-commit")
        }

        if canResumeRemoteReview(record) {
          Button {
            pendingDangerousReleaseAction = .resumeReview(record)
          } label: {
            releaseRecordActionLabel("继续创建 PR/MR", systemImage: "arrow.triangle.pull")
          }
          .disabled(store.isRemoteRepositoryPublishing)
          .accessibilityIdentifier("release-record-\(record.id)-resume-review")
        }

        if let reviewURL = record.reviewURL {
          Button {
            copy(reviewURL, message: "已复制 PR/MR 链接。")
          } label: {
            releaseRecordActionLabel("复制 PR/MR", systemImage: "doc.on.doc")
          }
          .accessibilityIdentifier("release-record-\(record.id)-copy-review")
        }

        if let url = record.reviewWebURL {
          Button {
            ExternalURLOpener.open(url)
          } label: {
            releaseRecordActionLabel("打开 PR/MR", systemImage: "arrow.up.right.square")
          }
          .accessibilityIdentifier("release-record-\(record.id)-open-review")
        }

        if let rollbackDraft {
          Button {
            copyRollbackDraft(rollbackDraft)
          } label: {
            releaseRecordActionLabel("复制回滚计划", systemImage: "arrow.uturn.backward")
          }
          .accessibilityIdentifier("release-record-\(record.id)-copy-rollback")

          if rollbackDraft.reviewTitle != nil || rollbackDraft.reviewBody != nil {
            Button {
              copyRollbackReviewDraft(rollbackDraft)
            } label: {
              releaseRecordActionLabel("复制回滚 PR/MR", systemImage: "arrow.triangle.pull")
            }
            .accessibilityIdentifier("release-record-\(record.id)-copy-rollback-review")
          }

          if let reviewURL = rollbackDraft.reviewURL.flatMap(URL.init(string:)) {
            Button {
              ExternalURLOpener.open(reviewURL)
            } label: {
              releaseRecordActionLabel("打开回滚 PR/MR", systemImage: "arrow.triangle.pull")
            }
            .accessibilityIdentifier("release-record-\(record.id)-open-rollback-review")
          }

          if let remoteURL = rollbackDraft.remoteURL.flatMap(URL.init(string:)) {
            Button {
              ExternalURLOpener.open(remoteURL)
            } label: {
              releaseRecordActionLabel("打开远端回滚", systemImage: "arrow.up.right.square")
            }
            .accessibilityIdentifier("release-record-\(record.id)-open-remote-rollback")
          }
        }

        if canWithdrawRemoteReview(record) {
          Button(role: .destructive) {
            pendingDangerousReleaseAction = .withdrawReview(record)
          } label: {
            releaseRecordActionLabel(
              "撤回线上 Review", systemImage: "arrow.down.forward.and.arrow.up.backward.circle")
          }
          .disabled(store.isRemoteRepositoryPublishing)
          .tint(WorkbenchTheme.risk)
          .accessibilityIdentifier("release-record-\(record.id)-withdraw-review")
        }

        if canRollbackRemoteRelease(record) {
          Button(role: .destructive) {
            pendingDangerousReleaseAction = .rollbackRemote(record)
          } label: {
            releaseRecordActionLabel("执行线上回滚", systemImage: "arrow.uturn.backward.circle")
          }
          .disabled(store.isRemoteRepositoryPublishing)
          .tint(WorkbenchTheme.risk)
          .accessibilityIdentifier("release-record-\(record.id)-rollback-remote")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-record-\(record.id)-actions")
  }

  private func releaseRecordActionLabel(
    _ title: LocalizedStringKey,
    systemImage: String
  ) -> some View {
    Label(title, systemImage: systemImage)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  func performDangerousReleaseAction(_ action: DangerousReleaseAction) async {
    switch action {
    case .resumeReview(let record):
      await store.resumeRemoteReview(record)
    case .withdrawReview(let record):
      await store.withdrawRemoteReview(record)
    case .rollbackRemote(let record):
      await store.rollbackRemoteRelease(record)
    }
  }

  func canResumeRemoteReview(_ record: ReleaseRecord) -> Bool {
    guard record.kind == .remotePublishFailure,
      record.reviewURL?.trimmedForPublishing.nilIfEmpty == nil,
      record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil,
      let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty,
      let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty
    else {
      return false
    }
    return branchName != targetBranch
  }

  func canRollbackRemoteRelease(_ record: ReleaseRecord) -> Bool {
    switch record.kind {
    case .remoteDirectCommit, .remotePublishFailure:
      return record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil
    case .localWrite, .batchLocalWrite, .directCommit, .reviewBranch, .remotePreviewBranch,
      .remoteReviewRequest, .remoteRollback, .remoteReviewWithdrawal:
      return false
    }
  }

  func canWithdrawRemoteReview(_ record: ReleaseRecord) -> Bool {
    switch record.kind {
    case .remoteReviewRequest:
      return record.reviewStatus?.state != .merged
        && record.reviewURL?.trimmedForPublishing.nilIfEmpty != nil
    case .localWrite, .batchLocalWrite, .directCommit, .reviewBranch, .remoteDirectCommit,
      .remotePreviewBranch, .remotePublishFailure, .remoteRollback, .remoteReviewWithdrawal:
      return false
    }
  }

}
