import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct ReleaseHistoryDetailView: View {
  let store: WorkbenchStore
  @ObservedObject private var historyObservation: WorkbenchReleaseHistoryObservationFacade
  @State var pendingDangerousReleaseAction: DangerousReleaseAction?

  init(
    store: WorkbenchStore,
    pendingDangerousReleaseAction: DangerousReleaseAction? = nil
  ) {
    self.store = store
    _historyObservation = ObservedObject(wrappedValue: store.releaseHistoryObservation)
    _pendingDangerousReleaseAction = State(wrappedValue: pendingDangerousReleaseAction)
  }

  var body: some View {
    let ledger = store.activeProfileReleaseLedger

    GeometryReader { geometry in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          releaseHistoryHeader(ledger)
          if let feedback = store.publishActionFeedback,
            feedback.message.nilIfEmpty != nil {
            releaseHistoryActionMessage(feedback)
          }
          releasePrimaryMetrics(ledger.summary)
          releaseSecondaryMetrics(ledger.summary)
          releaseOperationalContent(
            ledger,
            usesSplitLayout: WorkbenchPageMetrics.usesOperationalSplit(
              for: geometry.size.width
            )
          )
        }
        .workbenchOperationalPageLayout()
      }
    }
    .confirmationDialog(
      "确认危险操作",
      isPresented: pendingDangerousReleaseActionPresented,
      titleVisibility: .visible,
      presenting: pendingDangerousReleaseAction
    ) { action in
      Button(action.confirmButtonTitle, role: action.buttonRole) {
        Task {
          await performDangerousReleaseAction(action)
        }
      }
      Button("取消", role: .cancel) {}
    } message: { action in
      Text(action.confirmationMessage)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-release-history")
  }

  private func releaseHistoryActionMessage(_ feedback: PublishActionFeedback) -> some View {
    Label {
      Text(feedback.message)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    } icon: {
      Image(systemName: feedback.status.releaseHistorySystemImage)
    }
    .foregroundStyle(feedback.status.releaseHistoryForeground)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("release-history-action-message")
  }

  private func releaseHistoryHeader(_ ledger: ReleaseLedger) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        releaseHistoryHeaderIntroduction
        Spacer(minLength: 12)
        releaseHistoryHeaderActions(ledger)
      }

      VStack(alignment: .leading, spacing: 12) {
        releaseHistoryHeaderIntroduction
        releaseHistoryHeaderActions(ledger)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-header")
  }

  private var releaseHistoryHeaderIntroduction: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("发布记录")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text("追踪本地写入、Review、线上提交、部署状态和回滚计划。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func releaseHistoryHeaderActions(_ ledger: ReleaseLedger) -> some View {
    HStack(spacing: 10) {
      Button {
        copy(ledger.operationLogMarkdown, message: "已复制发布台账。")
      } label: {
        releaseHistoryActionLabel("复制台账", systemImage: "doc.on.doc")
      }
      .accessibilityIdentifier("release-history-copy-ledger")

      Text("\(ledger.summary.totalCount) 条")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func releaseOperationalContent(
    _ ledger: ReleaseLedger,
    usesSplitLayout: Bool
  ) -> some View {
    if usesSplitLayout {
      HStack(alignment: .top, spacing: 16) {
        releaseMainColumn(ledger)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        releaseDeploymentColumn(ledger)
          .frame(
            width: WorkbenchPageMetrics.operationalContextWidth,
            alignment: .topLeading
          )
      }
    } else {
      VStack(alignment: .leading, spacing: 16) {
        releaseActionQueueSection(ledger)
        deploymentOverviewSummary(ledger.deploymentOverview)
        deploymentPollingSummary
        deploymentStatusSummary
        releaseRecordsSection(ledger)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("release-history-narrow-content")
    }
  }

  private func releaseMainColumn(_ ledger: ReleaseLedger) -> some View {
    LazyVStack(alignment: .leading, spacing: 16) {
      releaseActionQueueSection(ledger)
      releaseRecordsSection(ledger)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-main-column")
  }

  private func releaseDeploymentColumn(_ ledger: ReleaseLedger) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      deploymentOverviewSummary(ledger.deploymentOverview)
      deploymentPollingSummary
      deploymentStatusSummary
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-deployment-column")
  }

  private func releaseRecordsSection(_ ledger: ReleaseLedger) -> some View {
    LazyVStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("发布记录", systemImage: "clock.arrow.circlepath")
          .font(.workbenchSectionTitle)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Text("\(ledger.entries.count) 条")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if ledger.entries.isEmpty {
        EmptyStateView(
          title: "还没有发布记录",
          message: "写入本地仓库或创建提交后，这里会记录文章、路径、分支和 PR/MR 信息。",
          systemImage: "clock.arrow.circlepath",
          density: .compactPane,
          actionTitle: "前往写作",
          actionSystemImage: "square.and.pencil",
          action: { store.selectSection(.writing) }
        )
        .frame(height: 260)
        .accessibilityIdentifier("release-history-empty-records")
      } else {
        ForEach(ReleaseHistoryPresentation.records(for: ledger.entries)) { presentation in
          switch presentation {
          case let .failureGroup(group):
            releaseFailureGroupCard(group)
          case let .entry(entry):
            releaseRecordCard(entry)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-records")
  }

  private func releaseFailureGroupCard(_ group: ReleaseHistoryFailureGroup) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label("重复失败", systemImage: "exclamationmark.triangle")
            .font(.callout.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.risk)
          Text("\(group.entries.count) 条")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Text("最近：\(group.latestDate.workbenchShortText)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(group.cause)
          .font(.callout.weight(.medium))
          .lineLimit(2)
        Text("受影响：\(group.affectedObjectSummary)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(group.entries) { entry in
          releaseRecordCard(entry)
        }
      }
      .padding(.top, 10)
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("重复失败分组")
    .accessibilityValue("\(group.cause)，\(group.entries.count) 条，最近 \(group.latestDate.workbenchShortText)")
    .accessibilityIdentifier("release-history-failure-group-\(RepositoryAccessibilityIdentifier.token(for: group.id))")
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

  private func releasePrimaryMetrics(_ summary: ReleaseLedgerSummary) -> some View {
    PrimaryStatusMetricGrid {
      MetricTile(
        title: "阻断",
        value: "\(summary.failedCount)",
        semantic: summary.failedCount == 0 ? .passed : .blocking
      )
      MetricTile(
        title: "待处理",
        value: "\(summary.actionItemCount)",
        semantic: summary.actionItemCount == 0 ? .passed : .warning
      )
      MetricTile(title: "已上线", value: "\(summary.succeededCount)", semantic: .passed)
    }
    .accessibilityIdentifier("release-history-primary-metrics")
  }

  private func releaseSecondaryMetrics(_ summary: ReleaseLedgerSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("台账指标", systemImage: "chart.bar.xaxis")
        .font(.workbenchSectionTitle)
        .accessibilityAddTraits(.isHeader)

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 138, maximum: 220))],
        spacing: 10
      ) {
        MetricTile(title: "全部记录", value: "\(summary.totalCount)", semantic: .neutral)
        MetricTile(title: "仅本地", value: "\(summary.localPendingCount)", semantic: .neutral)
        MetricTile(title: "等待合并", value: "\(summary.reviewPendingCount)", semantic: .progress)
        MetricTile(title: "等待部署", value: "\(summary.deploymentPendingCount)", semantic: .progress)
        MetricTile(
          title: "远端待确认",
          value: "\(summary.remoteRecoveryPendingCount)",
          semantic: summary.remoteRecoveryPendingCount == 0 ? .passed : .warning
        )
        MetricTile(title: "可回滚", value: "\(summary.rollbackAvailableCount)", semantic: .neutral)
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-secondary-metrics")
  }

  private func releaseActionQueueSection(_ ledger: ReleaseLedger) -> some View {
    LazyVStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("发布行动队列", systemImage: "checklist")
          .font(.workbenchSectionTitle)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Text("\(ledger.actionItems.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if ledger.actionItems.isEmpty {
        Label("当前没有需要处理的发布事项。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(ledger.actionItems) { item in
          releaseActionRow(item)
        }
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-action-queue")
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
              .workbenchTruncatedIdentity(item.title)
            Text(item.kind.localizedDisplayName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkbenchBackgroundStyle.control, in: Capsule())
            Spacer()
            Text(item.priority.localizedDisplayName)
              .font(.caption.weight(.semibold))
              .foregroundStyle(releaseActionPriorityForeground(item.priority))
          }

          Text(item.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if !item.detail.isEmpty {
            Text(item.detail)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .workbenchTruncatedIdentity(item.detail)
          }
        }
      }

      if !item.commandLines.isEmpty {
        ForEach(item.commandLines.prefix(2), id: \.self) { command in
          Text(command)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .lineLimit(2)
        }
      }

      let entry = store.activeProfileReleaseLedger.entries.first(where: { $0.id == item.recordID })
      releaseActionButtons(item, entry: entry)
      .controlSize(.regular)
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-action-row-\(item.id)")
  }

  @ViewBuilder
  private func releaseActionButtons(_ item: ReleaseLedgerActionItem, entry: ReleaseLedgerEntry?) -> some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
      alignment: .leading,
      spacing: 8
    ) {
      if !item.commandLines.isEmpty {
        Button {
          copy(item.commandLines.joined(separator: "\n"), message: "已复制发布处理命令。")
        } label: {
          releaseHistoryActionLabel("复制命令", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("release-action-\(item.id)-copy-command")
      }

      if let entry {
        if item.kind == .recoverPartialRemotePublish,
           canResumeRemoteReview(entry.record) {
          Button {
            pendingDangerousReleaseAction = .resumeReview(entry.record)
          } label: {
            releaseHistoryActionLabel("继续创建 PR/MR", systemImage: "arrow.triangle.pull")
          }
          .disabled(store.isRemoteRepositoryPublishing)
          .accessibilityIdentifier("release-action-\(item.id)-resume-review")
        }

        if item.kind.supportsDeploymentRecheck {
          deploymentRecheckButton(
            entry,
            accessibilityIdentifier: "release-action-\(item.id)-check-deployment"
          )
        }

        Button {
          copyRecoveryPackage(entry.recoveryPackage)
        } label: {
          releaseHistoryActionLabel("复制恢复包", systemImage: "shippingbox")
        }
        .accessibilityIdentifier("release-action-\(item.id)-copy-recovery")
      }

      if let remoteURL = item.remoteURL.flatMap(URL.init(string:)) {
        Button {
          ExternalURLOpener.open(remoteURL)
        } label: {
          releaseHistoryActionLabel("打开远端", systemImage: "arrow.up.right.square")
        }
        .accessibilityIdentifier("release-action-\(item.id)-open-remote")
      }
    }
    .buttonStyle(.bordered)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-action-\(item.id)-buttons")
  }

  private func deploymentRecheckButton(
    _ entry: ReleaseLedgerEntry,
    accessibilityIdentifier: String
  ) -> some View {
    Button {
      Task {
        await store.refreshDeploymentStatus(for: entry.record)
      }
    } label: {
      releaseHistoryActionLabel("重试检查", systemImage: "checkmark.icloud")
    }
    .disabled(store.isDeploymentStatusChecking || !store.canCheckDeploymentStatus(for: entry.record))
    .accessibilityIdentifier(accessibilityIdentifier)
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
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 74, alignment: .leading)
          Text(snapshot.level.localizedDisplayName)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusForeground(snapshot.level))
          Text(snapshot.message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  func deploymentPostPublishChecklist(_ deploymentStatus: DeploymentStatusSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("发布后校验清单", systemImage: "checklist.checked")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)

      ForEach(deploymentStatus.postPublishCheckItems) { item in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: item.level.systemImage)
            .foregroundStyle(statusForeground(item.level))
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
              .font(.callout.weight(.medium))
            Text(item.message)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if let urlText = item.urlText?.nilIfEmpty {
              Text(urlText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .workbenchTruncatedIdentity(urlText)
            }
          }
          Spacer(minLength: 0)
        }
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func deploymentOverviewSummary(_ overview: ReleaseDeploymentOverview) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(overview.title, systemImage: overview.level.systemImage)
        .font(.workbenchSectionTitle)
        .foregroundStyle(statusForeground(overview.level))
        .accessibilityAddTraits(.isHeader)
      Text(overview.message)
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(overview.nextActionTitle)
        .font(.callout.weight(.medium))
        .foregroundStyle(statusForeground(overview.level))

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 112), spacing: 8)],
        spacing: 8
      ) {
        MetricTile(title: "已检查", value: "\(overview.checkedRecordCount)", semantic: .passed)
        MetricTile(
          title: "未检查",
          value: "\(overview.uncheckedDeploymentCount)",
          semantic: overview.uncheckedDeploymentCount == 0 ? .passed : .warning
        )
        MetricTile(
          title: "运行中",
          value: "\(overview.runningDeploymentCount)",
          semantic: overview.runningDeploymentCount == 0 ? .neutral : .progress
        )
        MetricTile(
          title: "失败",
          value: "\(overview.failedDeploymentCount)",
          semantic: overview.failedDeploymentCount == 0 ? .passed : .blocking
        )
      }

      if let lastCheckedAt = overview.lastCheckedAt {
        Label("最近检查：\(lastCheckedAt.workbenchShortText)", systemImage: "clock.arrow.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(overview.nextActionMessage)
        .font(.callout)
        .foregroundStyle(.secondary)

      ForEach(overview.highlightedSignals) { signal in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: signal.level.systemImage)
            .foregroundStyle(statusForeground(signal.level))
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text(signal.title)
              .font(.callout.weight(.medium))
            Text(signal.message)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-deployment-overview")
  }

  @ViewBuilder
  private var deploymentPollingSummary: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("远端发布状态自动检查")
        .font(.workbenchSectionTitle)
        .accessibilityAddTraits(.isHeader)
      Text(store.deploymentPollingState.message)
        .font(.callout)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Button {
          copy(
            store.deploymentPollingState.followUpChecklistMarkdown,
            message: "已复制远端发布状态后续清单。"
          )
        } label: {
          releaseHistoryActionLabel("复制清单", systemImage: "checklist")
        }
        .disabled(
          store.deploymentPollingState.checkedRecordCount == 0
            && store.deploymentPollingState.reviewFailureCount == 0
        )
        .accessibilityLabel("复制远端发布状态检查清单")
        .accessibilityIdentifier("release-history-polling-copy-checklist")
        Button {
          Task {
            await store.runDeploymentPolling()
          }
        } label: {
          releaseHistoryActionLabel("立即检查", systemImage: "arrow.clockwise")
        }
        .disabled(!store.deploymentPollingSettings.isEnabled || store.isDeploymentStatusChecking)
        .accessibilityLabel("立即检查 PR/MR 与部署状态")
        .accessibilityIdentifier("release-history-polling-run-now")
      }

      VStack(alignment: .leading, spacing: 8) {
        Toggle("启用 PR/MR 与部署状态自动检查", isOn: deploymentPollingEnabledBinding)
          .toggleStyle(.switch)
          .accessibilityLabel("启用 PR/MR 与部署状态自动检查")
          .accessibilityValue(store.deploymentPollingSettings.isEnabled ? "开启" : "关闭")
          .accessibilityIdentifier("release-history-polling-enabled")

        Picker("最短检查间隔", selection: deploymentPollingIntervalBinding) {
          ForEach(deploymentPollingIntervalOptions, id: \.self) { minutes in
            Text("\(minutes) 分钟").tag(minutes)
          }
        }
        .pickerStyle(.segmented)
        .tint(WorkbenchTheme.navigationSelection)
        .frame(maxWidth: 320)
        .disabled(!store.deploymentPollingSettings.isEnabled || store.isDeploymentStatusChecking)
        .accessibilityLabel("远端发布状态自动检查最短间隔")
        .accessibilityValue("\(store.deploymentPollingSettings.normalizedIntervalMinutes) 分钟")
        .accessibilityIdentifier("release-history-polling-interval")
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
        MetricTile(
          title: "状态",
          value: store.deploymentPollingSettings.isEnabled ? store.deploymentPollingState.status.localizedDisplayName : "已关闭",
          systemImage: store.deploymentPollingState.status.systemImage
        )
        MetricTile(
          title: "待合并",
          value: "\(store.remoteReviewPollingEligibleRecordCount)",
          systemImage: "arrow.triangle.pull"
        )
        MetricTile(
          title: "待部署",
          value: "\(store.deploymentPollingEligibleRecords.count)",
          systemImage: "hourglass"
        )
        MetricTile(
          title: "最短间隔",
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
          Label("可再次自动检查：\(nextRunAt.workbenchShortText)", systemImage: "clock")
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
                Text(checkedRecord.title)
                  .font(.callout.weight(.semibold))
                  .workbenchTruncatedIdentity(checkedRecord.title)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text(checkedRecord.provider.localizedDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Text(checkedRecord.level.localizedDisplayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusForeground(checkedRecord.level))
                  Text(checkedRecord.checkedAt.workbenchShortText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(checkedRecord.message)
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 0)
            }
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-deployment-polling")
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
      Text("部署状态")
        .font(.workbenchSectionTitle)
        .accessibilityAddTraits(.isHeader)
      Text("检查 GitHub Pages / Actions、GitLab Pipeline，或 Netlify、Vercel、Cloudflare Pages、自定义状态端点。")
        .font(.callout)
        .foregroundStyle(.secondary)
      if let latestRecord = store.activeProfileReleaseRecords.first,
         store.canCheckDeploymentStatus(for: latestRecord) {
        Button {
          Task {
            await store.refreshDeploymentStatus(for: latestRecord)
          }
        } label: {
          releaseHistoryActionLabel("刷新最新", systemImage: "arrow.clockwise")
        }
        .disabled(store.isDeploymentStatusChecking)
        .accessibilityIdentifier("release-history-deployment-refresh-latest")
      }

      Label(
        readiness.statusTitle,
        systemImage: readiness.isAPIReady ? "checkmark.seal" : readiness.canCheckAnyStatus ? "exclamationmark.triangle" : "xmark.octagon"
      )
      .font(.callout.weight(.medium))
      .foregroundStyle(readiness.isAPIReady ? WorkbenchTheme.success : readiness.canCheckAnyStatus ? WorkbenchTheme.warning : WorkbenchTheme.risk)

      VStack(alignment: .leading, spacing: 4) {
        Label(readiness.provider.integrationDepth.title, systemImage: readiness.provider.systemImage)
          .font(.callout.weight(.semibold))
        Text(readiness.provider.integrationDepth.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(8)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

      if !readiness.missingRequirements.isEmpty {
        Text("待补齐：\(readiness.missingRequirements.joined(separator: "、"))")
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      if store.isDeploymentStatusChecking {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在检查部署状态…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } else if let message = store.deploymentStatusMessage {
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Text("发布后可在每条记录上手动检查部署状态；线上发布成功后会自动检查一次。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-deployment-status")
  }


  func metadataRow(_ title: LocalizedStringKey, _ value: String) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospaced())
        .workbenchTruncatedIdentity(value)
    }
  }

  func metadataTextRow(_ title: LocalizedStringKey, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospaced())
        .workbenchTruncatedIdentity(value)
    }
  }

  private func releaseHistoryActionLabel(
    _ title: LocalizedStringKey,
    systemImage: String
  ) -> some View {
    Label(title, systemImage: systemImage)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { message, status in
      store.setPublishActionMessage(message, status: status)
    }
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
    case .localOnly, .previewOnly, .reviewWithdrawn, .unknown:
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

extension PublishActionMessageStatus {
  fileprivate var releaseHistorySystemImage: String {
    switch self {
    case .information:
      return "info.circle.fill"
    case .inProgress:
      return "arrow.trianglehead.2.clockwise.rotate.90"
    case .success:
      return "checkmark.circle.fill"
    case .warning:
      return "exclamationmark.triangle.fill"
    case .failure:
      return "xmark.octagon.fill"
    }
  }

  fileprivate var releaseHistoryForeground: Color {
    switch self {
    case .information:
      return WorkbenchTheme.info
    case .inProgress:
      return WorkbenchTheme.progress
    case .success:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .failure:
      return WorkbenchTheme.risk
    }
  }
}
