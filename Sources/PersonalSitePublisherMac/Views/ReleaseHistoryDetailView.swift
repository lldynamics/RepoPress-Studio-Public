import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct ReleaseHistoryDetailView: View {
  @ObservedObject var store: WorkbenchStore
#if DEBUG
  @State var webhookProvider: DeploymentProvider = .netlify
  @State var webhookPayloadText = ""
#endif
  @State var pendingDangerousReleaseAction: DangerousReleaseAction?

  var body: some View {
    let ledger = store.activeProfileReleaseLedger

    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text("发布台账")
              .font(.title2.weight(.semibold))
            Text("追踪本地写入、Review、线上提交、部署状态和回滚计划。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            copy(ledger.operationLogMarkdown, message: "已复制发布台账。")
          } label: {
            Label("复制台账", systemImage: "doc.on.doc")
          }
          Text("\(ledger.summary.totalCount) 条")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 138, maximum: 220))], spacing: 12) {
          MetricTile(
            title: "待处理",
            value: "\(ledger.summary.actionItemCount)",
            semantic: ledger.summary.actionItemCount == 0 ? .passed : .warning
          )
          MetricTile(title: "等待合并", value: "\(ledger.summary.reviewPendingCount)", semantic: .progress)
          MetricTile(title: "等待部署", value: "\(ledger.summary.deploymentPendingCount)", semantic: .progress)
          MetricTile(
            title: "远端待确认",
            value: "\(ledger.summary.remoteRecoveryPendingCount)",
            semantic: ledger.summary.remoteRecoveryPendingCount == 0 ? .passed : .warning
          )
          MetricTile(title: "已上线", value: "\(ledger.summary.succeededCount)", semantic: .passed)
          MetricTile(
            title: "失败",
            value: "\(ledger.summary.failedCount)",
            semantic: ledger.summary.failedCount == 0 ? .passed : .blocking
          )
        }

        deploymentOverviewSummary(ledger.deploymentOverview)
        releaseActionQueueSection(ledger)
        deploymentPollingSummary
        deploymentStatusSummary
#if DEBUG
        deploymentAdvancedDebugSection
#endif

        if ledger.entries.isEmpty {
          EmptyStateView(
            title: "还没有发布记录",
            message: "写入本地仓库或创建提交后，这里会记录文章、路径、分支和 PR/MR 信息。",
            systemImage: "clock.arrow.circlepath",
            actionTitle: "前往写作",
            actionSystemImage: "square.and.pencil",
            action: { store.selectSection(.writing) }
          )
          .frame(height: 260)
        } else {
          ForEach(ledger.entries) { entry in
            releaseRecordCard(entry)
          }
        }
      }
      .padding(20)
    }
    .confirmationDialog(
      "确认危险操作",
      isPresented: pendingDangerousReleaseActionPresented,
      titleVisibility: .visible,
      presenting: pendingDangerousReleaseAction
    ) { action in
      Button(action.confirmButtonTitle, role: .destructive) {
        Task {
          await performDangerousReleaseAction(action)
        }
      }
      Button("取消", role: .cancel) {}
    } message: { action in
      Text(action.confirmationMessage)
    }
    
  }

  private var pendingDangerousReleaseActionPresented: Binding<Bool> {
    Binding(
      get: { pendingDangerousReleaseAction != nil },
      set: { isPresented in
        if !isPresented {
          pendingDangerousReleaseAction = nil
        }
      }
    )
  }

  private func releaseActionQueueSection(_ ledger: ReleaseLedger) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("发布行动队列", systemImage: "checklist")
          .font(.headline)
        Spacer()
        Text("\(ledger.actionItems.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if ledger.actionItems.isEmpty {
        Label("当前没有需要处理的发布事项。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(ledger.actionItems.prefix(6)) { item in
          releaseActionRow(item)
        }
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func releaseActionRow(_ item: ReleaseLedgerActionItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: item.systemImage)
          .foregroundStyle(releaseActionPriorityForeground(item.priority))
          .frame(width: 18)

        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.title)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Text(item.kind.localizedDisplayName)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkbenchBackgroundStyle.badge, in: Capsule())
            Spacer()
            Text(item.priority.localizedDisplayName)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(releaseActionPriorityForeground(item.priority))
          }

          Text(item.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)

          if !item.detail.isEmpty {
            Text(item.detail)
              .font(.caption2.monospaced())
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }

      if !item.commandLines.isEmpty {
        ForEach(item.commandLines.prefix(2), id: \.self) { command in
          Text(command)
            .font(.caption2.monospaced())
            .textSelection(.enabled)
            .lineLimit(2)
        }
      }

      HStack {
        if !item.commandLines.isEmpty {
          Button {
            copy(item.commandLines.joined(separator: "\n"), message: "已复制发布处理命令。")
          } label: {
            Label("复制命令", systemImage: "doc.on.doc")
          }
        }

        if let entry = store.activeProfileReleaseLedger.entries.first(where: { $0.id == item.recordID }) {
          if item.kind.supportsDeploymentRecheck {
            Button {
              Task {
                await store.refreshDeploymentStatus(for: entry.record)
              }
            } label: {
              Label("重试检查", systemImage: "checkmark.icloud")
            }
            .disabled(store.isDeploymentStatusChecking || !store.canCheckDeploymentStatus(for: entry.record))
          }

          Button {
            copyRecoveryPackage(entry.recoveryPackage)
          } label: {
            Label("复制恢复包", systemImage: "shippingbox")
          }

        }

        if let remoteURL = item.remoteURL.flatMap(URL.init(string:)) {
          Button {
            ExternalURLOpener.open(remoteURL)
          } label: {
            Label("打开远端", systemImage: "arrow.up.right.square")
          }
        }
      }
      .controlSize(.small)
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }


  func deploymentStatusHistoryTimeline(_ history: [DeploymentStatusSnapshot]) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("最近校验", systemImage: "clock.arrow.circlepath")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ForEach(history.prefix(4)) { snapshot in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: snapshot.level.systemImage)
            .foregroundStyle(statusForeground(snapshot.level))
            .frame(width: 16)
          Text(snapshot.checkedAt.workbenchShortText)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 74, alignment: .leading)
          Text(snapshot.level.localizedDisplayName)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusForeground(snapshot.level))
          Text(snapshot.message)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  func deploymentPostPublishChecklist(_ deploymentStatus: DeploymentStatusSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("发布后校验清单", systemImage: "checklist.checked")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ForEach(deploymentStatus.postPublishCheckItems) { item in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: item.level.systemImage)
            .foregroundStyle(statusForeground(item.level))
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
              .font(.caption.weight(.medium))
            Text(item.message)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
            if let urlText = item.urlText?.nilIfEmpty {
              Text(urlText)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)
            }
          }
          Spacer(minLength: 0)
        }
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func deploymentOverviewSummary(_ overview: ReleaseDeploymentOverview) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Label(overview.title, systemImage: overview.level.systemImage)
            .font(.headline)
            .foregroundStyle(statusForeground(overview.level))
          Text(overview.message)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(overview.nextActionTitle)
          .font(.caption.weight(.medium))
          .foregroundStyle(statusForeground(overview.level))
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        MetricTile(title: "已检查", value: "\(overview.checkedRecordCount)", systemImage: "checkmark.icloud")
        MetricTile(title: "未检查", value: "\(overview.uncheckedDeploymentCount)", systemImage: "clock.badge.questionmark")
        MetricTile(title: "运行中", value: "\(overview.runningDeploymentCount)", systemImage: "hourglass")
        MetricTile(title: "失败", value: "\(overview.failedDeploymentCount)", systemImage: "xmark.octagon")
      }

      if let lastCheckedAt = overview.lastCheckedAt {
        Label("最近检查：\(lastCheckedAt.workbenchShortText)", systemImage: "clock.arrow.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(overview.nextActionMessage)
        .font(.caption)
        .foregroundStyle(.secondary)

      ForEach(overview.highlightedSignals) { signal in
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
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  @ViewBuilder
  private var deploymentPollingSummary: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("部署轮询")
            .font(.headline)
          Text(store.deploymentPollingState.message)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          copy(
            store.deploymentPollingState.followUpChecklistMarkdown,
            message: "已复制部署轮询后续清单。"
          )
        } label: {
          Label("复制清单", systemImage: "checklist")
        }
        .disabled(store.deploymentPollingState.checkedRecords.isEmpty)
        .accessibilityLabel("复制部署轮询清单")
        Button {
          Task {
            await store.runDeploymentPolling()
          }
        } label: {
          Label("立即轮询", systemImage: "arrow.clockwise")
        }
        .disabled(!store.deploymentPollingSettings.isEnabled || store.isDeploymentStatusChecking)
        .accessibilityLabel("立即执行部署轮询")
      }

      HStack(spacing: 12) {
        Toggle("启用部署轮询", isOn: deploymentPollingEnabledBinding)
          .toggleStyle(.switch)
          .accessibilityLabel("启用部署轮询")
          .accessibilityValue(store.deploymentPollingSettings.isEnabled ? "开启" : "关闭")

        Spacer()

        Picker("轮询间隔", selection: deploymentPollingIntervalBinding) {
          ForEach(deploymentPollingIntervalOptions, id: \.self) { minutes in
            Text("\(minutes) 分钟").tag(minutes)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .disabled(!store.deploymentPollingSettings.isEnabled || store.isDeploymentStatusChecking)
        .accessibilityLabel("部署轮询间隔")
        .accessibilityValue("\(store.deploymentPollingSettings.normalizedIntervalMinutes) 分钟")
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        MetricTile(
          title: "状态",
          value: store.deploymentPollingSettings.isEnabled ? store.deploymentPollingState.status.localizedDisplayName : "已关闭",
          systemImage: store.deploymentPollingState.status.systemImage
        )
        MetricTile(
          title: "待轮询",
          value: "\(store.deploymentPollingEligibleRecords.count)",
          systemImage: "hourglass"
        )
        MetricTile(
          title: "间隔",
          value: store.deploymentPollingSettings.isEnabled ? "\(store.deploymentPollingSettings.normalizedIntervalMinutes) 分钟" : "-",
          systemImage: "timer"
        )
        MetricTile(
          title: "正常",
          value: "\(store.deploymentPollingState.successCount)",
          systemImage: DeploymentStatusLevel.success.systemImage
        )
        MetricTile(
          title: "部署中",
          value: "\(store.deploymentPollingState.runningCount)",
          systemImage: DeploymentStatusLevel.running.systemImage
        )
        MetricTile(
          title: "需处理",
          value: "\(store.deploymentPollingState.attentionCount)",
          systemImage: store.deploymentPollingState.attentionCount > 0 ? DeploymentStatusLevel.failed.systemImage : "checkmark.circle"
        )
      }

      HStack(spacing: 12) {
        if let lastRunAt = store.deploymentPollingState.lastRunAt {
          Label("上次：\(lastRunAt.workbenchShortText)", systemImage: "clock.arrow.circlepath")
        }
        if let nextRunAt = store.deploymentPollingState.nextRunAt, store.deploymentPollingSettings.isEnabled {
          Label("下次：\(nextRunAt.workbenchShortText)", systemImage: "clock")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if !store.deploymentPollingState.checkedRecords.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Label("最近检查记录", systemImage: "checkmark.icloud")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          ForEach(store.deploymentPollingState.checkedRecords.prefix(5)) { checkedRecord in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: checkedRecord.level.systemImage)
                .foregroundStyle(statusForeground(checkedRecord.level))
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text(checkedRecord.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                  Text(checkedRecord.provider.localizedDisplayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Text(checkedRecord.level.localizedDisplayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusForeground(checkedRecord.level))
                }
                Text(checkedRecord.message)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              Spacer(minLength: 0)
              Text(checkedRecord.checkedAt.workbenchShortText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var deploymentPollingIntervalOptions: [Int] {
    [
      DeploymentPollingSettings.minimumIntervalMinutes,
      10,
      15,
      30,
      DeploymentPollingSettings.maximumIntervalMinutes,
    ]
  }

  private var deploymentPollingEnabledBinding: Binding<Bool> {
    Binding(
      get: { store.deploymentPollingSettings.isEnabled },
      set: { isEnabled in
        store.updateDeploymentPollingSettings(
          DeploymentPollingSettings(
            isEnabled: isEnabled,
            intervalMinutes: store.deploymentPollingSettings.normalizedIntervalMinutes
          )
        )
      }
    )
  }

  private var deploymentPollingIntervalBinding: Binding<Int> {
    Binding(
      get: { store.deploymentPollingSettings.normalizedIntervalMinutes },
      set: { intervalMinutes in
        store.updateDeploymentPollingSettings(
          DeploymentPollingSettings(
            isEnabled: store.deploymentPollingSettings.isEnabled,
            intervalMinutes: intervalMinutes
          )
        )
      }
    )
  }

  @ViewBuilder
  private var deploymentStatusSummary: some View {
    let readiness = store.activeDeploymentStatusReadiness

    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("部署状态")
            .font(.headline)
          Text("检查 GitHub Pages / Actions、GitLab Pipeline，或 Netlify、Vercel、Cloudflare Pages、自定义状态端点。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let latestRecord = store.activeProfileReleaseRecords.first, store.canCheckDeploymentStatus(for: latestRecord) {
          Button {
            Task {
              await store.refreshDeploymentStatus(for: latestRecord)
            }
          } label: {
            Label("刷新最新", systemImage: "arrow.clockwise")
          }
          .disabled(store.isDeploymentStatusChecking)
        }
      }

      Label(
        readiness.statusTitle,
        systemImage: readiness.isAPIReady ? "checkmark.seal" : readiness.canCheckAnyStatus ? "exclamationmark.triangle" : "xmark.octagon"
      )
      .font(.caption.weight(.medium))
      .foregroundStyle(readiness.isAPIReady ? .green : readiness.canCheckAnyStatus ? .orange : .red)

      VStack(alignment: .leading, spacing: 4) {
        Label(readiness.provider.integrationDepth.title, systemImage: readiness.provider.systemImage)
          .font(.caption.weight(.semibold))
        Text(readiness.provider.integrationDepth.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(8)
      .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

      if !readiness.missingRequirements.isEmpty {
        Text("待补齐：\(readiness.missingRequirements.joined(separator: "、"))")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      if store.isDeploymentStatusChecking {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在检查部署状态...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let message = store.deploymentStatusMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("发布后可在每条记录上手动检查部署状态；线上发布成功后会自动检查一次。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }


  func metadataRow(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospaced())
        .lineLimit(1)
        .textSelection(.enabled)
    }
  }

  func metadataTextRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption2.monospaced())
        .lineLimit(1)
        .textSelection(.enabled)
    }
  }

  func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }

  func statusForeground(_ level: DeploymentStatusLevel) -> AnyShapeStyle {
    switch level {
    case .success:
      return AnyShapeStyle(WorkbenchTheme.success)
    case .running:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .failed:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .unknown:
      return AnyShapeStyle(.secondary)
    }
  }

  func ledgerStatusForeground(_ status: ReleaseLedgerStatus) -> AnyShapeStyle {
    switch status {
    case .succeeded:
      return AnyShapeStyle(WorkbenchTheme.success)
    case .deploying, .pendingDeployment, .pendingRemoteRecovery, .pendingRetry, .pendingReview:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .failed:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .localOnly, .unknown:
      return AnyShapeStyle(.secondary)
    }
  }

  private func releaseActionPriorityForeground(_ priority: ReleaseLedgerActionPriority) -> AnyShapeStyle {
    switch priority {
    case .high:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .medium:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .low:
      return AnyShapeStyle(.secondary)
    }
  }

  func copyRollbackDraft(_ draft: ReleaseRollbackDraft) {
    var blocks = [draft.title, draft.summary]
    if let branchName = draft.reviewBranchName {
      blocks.append("回滚分支：\(branchName)")
    }
    blocks.append(contentsOf: draft.commandLines)
    let text = blocks.joined(separator: "\n")
    copy(text, message: "已复制回滚计划。")
  }

  func copyRollbackReviewDraft(_ draft: ReleaseRollbackDraft) {
    let text = [
      draft.reviewBranchName.map { "Branch: \($0)" },
      draft.reviewTitle.map { "Title: \($0)" },
      draft.reviewBody
    ]
    .compactMap { $0?.trimmedForPublishing.nilIfEmpty }
    .joined(separator: "\n\n")
    copy(text, message: "已复制回滚 PR/MR 草稿。")
  }

  func copyRecoveryPackage(_ package: ReleaseRecoveryPackage) {
    copy(package.clipboardMarkdown, message: "已复制发布恢复包。")
  }

}
