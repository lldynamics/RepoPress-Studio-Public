import AppKit
import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

struct ReleaseHistoryDetailView: View {
  let store: WorkbenchStore
  let focusedRecordID: UUID?
  @ObservedObject private var historyObservation: WorkbenchReleaseHistoryObservationFacade
  @State var pendingDangerousReleaseAction: DangerousReleaseAction?
  @State private var showsAllRecords = false
  @State var pendingFailureReview: ReleaseRecord?
  @State private var expandedCommandActionIDs: Set<String> = []

  init(
    store: WorkbenchStore,
    focusedRecordID: UUID? = nil,
    pendingDangerousReleaseAction: DangerousReleaseAction? = nil
  ) {
    self.store = store
    self.focusedRecordID = focusedRecordID
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
          if let focusedRecordID, !showsAllRecords {
            focusedReleaseRecordContent(focusedRecordID)
          } else {
            // Show execution details only when this site has an attempt to
            // inspect; the release-record empty state covers a new site.
            if store.publishExecutionRecords.contains(where: {
              $0.plan.target.profileID == store.activeProfileID
            }) {
              PublishExecutionHistorySection(
                store: store,
                activeProfileID: store.activeProfileID,
                records: store.publishExecutionRecords
              )
            }
            releaseOperationalContent(
              ledger,
              usesSplitLayout: WorkbenchPageMetrics.usesOperationalSplit(
                for: geometry.size.width
              )
            )
          }
        }
        .workbenchOperationalPageLayout()
      }
    }
    .confirmationDialog(
      String(localized: "确认危险操作"),
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
    .sheet(item: $pendingFailureReview) { record in
      ReleaseFailureReviewSheet(store: store, record: record)
    }
  }

  func beginFailureReview(_ record: ReleaseRecord) {
    guard !store.isRemoteRepositoryPublishing,
      store.activeProfileReleaseRecords.contains(where: { $0.id == record.id }),
      ReleaseFailureReviewContext.canReview(
        record,
        profile: store.activeProfile,
        drafts: store.drafts,
        batchPlan: store.batchPublishPlan
      )
    else { return }
    if let draftID = record.draftID, record.batchItems.isEmpty {
      // Preserve the history surface that owns the review sheet.
      guard store.focusDraft(draftID) else { return }
    }
    pendingFailureReview = record
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
      Text("发布历史")
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
      if focusedRecordID != nil, !showsAllRecords {
        Button(String(localized: "查看全部记录")) {
          showsAllRecords = true
        }
        .accessibilityIdentifier("release-history-show-all-records")
      }
      Button {
        copy(ledger.operationLogMarkdown, message: String(localized: "已复制发布记录。"))
      } label: {
        Label("复制发布记录", systemImage: "doc.on.doc")
          .fixedSize(horizontal: true, vertical: false)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityIdentifier("release-history-copy-ledger")

    }
  }

  @ViewBuilder
  private func focusedReleaseRecordContent(_ recordID: UUID) -> some View {
    if let record = store.releaseRecords.first(where: { $0.id == recordID }) {
      VStack(alignment: .leading, spacing: 14) {
        if let profileID = record.siteProfileID, profileID != store.activeProfileID {
          Label {
            Text(String(localized: "该发布记录属于另一个站点；当前未自动替换为其它记录。"))
          } icon: {
            Image(systemName: "arrow.triangle.branch")
          }
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.risk)
          .accessibilityIdentifier("release-history-focused-record-site-changed")
        }

        Label(String(localized: "已定位到指定发布记录"), systemImage: "scope")
          .font(.headline)
        releaseRecordCard(store.releaseLedgerEntry(for: record))
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("release-history-focused-record")
    } else {
      ContentUnavailableView(
        String(localized: "发布记录已不可用"),
        systemImage: "exclamationmark.triangle",
        description: Text(String(localized: "该发布记录已被清理或当前无权访问；未跳转到其他记录。"))
      )
      .frame(maxWidth: .infinity, minHeight: 260)
      .accessibilityIdentifier("release-history-focused-record-unavailable")
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
        deploymentPollingSummary
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
      deploymentPollingSummary
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
        if !ledger.entries.isEmpty {
          Text("\(ledger.entries.count) 条")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
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

  @ViewBuilder
  private func releaseActionQueueSection(_ ledger: ReleaseLedger) -> some View {
    if !ledger.actionItems.isEmpty {
      LazyVStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("发布行动队列", systemImage: "checklist")
            .font(.workbenchSectionTitle)
            .accessibilityAddTraits(.isHeader)
          Spacer()
        }

        ForEach(ledger.actionItems) { item in
          releaseActionRow(item)
        }
      }
      .padding(12)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("release-history-action-queue")
    }
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
            releaseActionPriorityBadge(item.priority)
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
        releaseActionCommandDisclosure(item)
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

  private func releaseActionPriorityBadge(_ priority: ReleaseLedgerActionPriority) -> some View {
    Text(priority.localizedDisplayName)
      .font(.callout.weight(.bold))
      .foregroundStyle(releaseActionPriorityForeground(priority))
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(releaseActionPriorityBackground(priority), in: Capsule())
      .accessibilityLabel("优先级：\(priority.localizedDisplayName)")
  }

  private func releaseActionCommandDisclosure(_ item: ReleaseLedgerActionItem) -> some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { expandedCommandActionIDs.contains(item.id) },
        set: { isExpanded in
          if isExpanded {
            expandedCommandActionIDs.insert(item.id)
          } else {
            expandedCommandActionIDs.remove(item.id)
          }
        }
      )
    ) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(item.commandLines, id: \.self) { command in
          Text(command)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 6)
    } label: {
      Label("高级：命令行（\(item.commandLines.count) 条）", systemImage: "terminal")
        .font(.callout.weight(.medium))
    }
    .accessibilityIdentifier("release-action-\(item.id)-advanced-commands")
    .accessibilityLabel("高级命令行，\(item.commandLines.count) 条")
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
          copy(item.commandLines.joined(separator: "\n"), message: String(localized: "已复制发布处理命令。"))
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
            message: String(localized: "已复制远端发布状态后续清单。")
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
            await store.runDeploymentPollingManually()
          }
        } label: {
          releaseHistoryActionLabel("立即检查", systemImage: "arrow.clockwise")
        }
        .disabled(store.isDeploymentStatusChecking)
        .accessibilityLabel("立即检查 PR/MR 与部署状态")
        .accessibilityIdentifier("release-history-polling-run-now")
      }

      HStack(spacing: 12) {
        if let lastRunAt = store.deploymentPollingState.lastRunAt {
          Label("上次检查：\(lastRunAt.workbenchShortText)", systemImage: "clock.arrow.circlepath")
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

  private func releaseActionPriorityBackground(_ priority: ReleaseLedgerActionPriority) -> Color {
    switch priority {
    case .high:
      return WorkbenchTheme.risk.opacity(0.14)
    case .medium:
      return WorkbenchTheme.warning.opacity(0.14)
    case .low:
      return Color.secondary.opacity(0.12)
    }
  }

  func copyRollbackDraft(_ draft: ReleaseRollbackDraft) {
    var blocks = [draft.title, draft.summary]
    if let branchName = draft.reviewBranchName {
      blocks.append("回滚分支：\(branchName)")
    }
    blocks.append(contentsOf: draft.commandLines)
    let text = blocks.joined(separator: "\n")
    copy(text, message: String(localized: "已复制回滚计划。"))
  }

  func copyRollbackReviewDraft(_ draft: ReleaseRollbackDraft) {
    let text = [
      draft.reviewBranchName.map { "Branch: \($0)" },
      draft.reviewTitle.map { "Title: \($0)" },
      draft.reviewBody
    ]
    .compactMap { $0?.trimmedForPublishing.nilIfEmpty }
    .joined(separator: "\n\n")
    copy(text, message: String(localized: "已复制回滚 PR/MR 草稿。"))
  }

  func copyRecoveryPackage(_ package: ReleaseRecoveryPackage) {
    copy(package.clipboardMarkdown, message: String(localized: "已复制发布恢复包。"))
  }

}
