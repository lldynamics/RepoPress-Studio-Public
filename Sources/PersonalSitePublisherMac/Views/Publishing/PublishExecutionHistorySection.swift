import PublishingWorkbenchCore
import SwiftUI

/// The recent, immutable publish attempts for the selected site profile.
/// Pending remote outcomes are always retained in the compact presentation so
/// an author cannot lose the only route to read-only verification.
struct PublishExecutionHistorySection: View {
  let store: WorkbenchStore
  let activeProfileID: UUID
  let records: [PublishExecutionRecord]
  @State private var verifyingRecordID: UUID?

  private var displayedRecords: [PublishExecutionRecord] {
    let matching =
      records
      .filter { $0.plan.target.profileID == activeProfileID }
      .sorted { $0.createdAt > $1.createdAt }
    let pendingIDs = Set(matching.filter { $0.state.needsVerification }.map(\.id))
    let recent = Array(matching.prefix(5))
    let pending = matching.filter { pendingIDs.contains($0.id) }
    let visibleIDs = Set(recent.map(\.id) + pending.map(\.id))
    return matching.filter { visibleIDs.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          sectionHeading
          Spacer(minLength: 10)
          countSummary
        }

        VStack(alignment: .leading, spacing: 4) {
          sectionHeading
          countSummary
        }
      }

      if displayedRecords.isEmpty {
        Text("当前站点还没有发布执行记录。")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        let firstPendingRecordID = displayedRecords.first(where: { $0.state.needsVerification })?.id
        ForEach(displayedRecords) { record in
          executionRecordCard(
            record,
            showsVerificationShortcut: record.id == firstPendingRecordID
          )
        }
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-execution-records")
    .accessibilityLabel("最近发布执行")
    .accessibilityValue("\(displayedRecords.count) 条")
  }

  private var sectionHeading: some View {
    Label("最近发布执行", systemImage: "arrow.triangle.2.circlepath")
      .font(.workbenchSectionTitle)
      .accessibilityAddTraits(.isHeader)
  }

  private var countSummary: some View {
    let pendingCount = displayedRecords.filter { $0.state.needsVerification }.count
    return Text(
      pendingCount == 0
        ? "最近 \(displayedRecords.count) 条"
        : "待核实 \(pendingCount) 条 · 最近 \(displayedRecords.count) 条"
    )
    .font(.caption.monospacedDigit())
    .foregroundStyle(pendingCount == 0 ? .secondary : WorkbenchTheme.risk)
  }

  private func executionRecordCard(
    _ record: PublishExecutionRecord,
    showsVerificationShortcut: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          executionSummary(record)
          Spacer(minLength: 10)
          verificationAction(record, showsKeyboardShortcut: showsVerificationShortcut)
        }

        VStack(alignment: .leading, spacing: 8) {
          executionSummary(record)
          verificationAction(record, showsKeyboardShortcut: showsVerificationShortcut)
        }
      }

      if let message = record.message?.trimmingCharacters(in: .whitespacesAndNewlines),
        !message.isEmpty
      {
        Text(message)
          .font(.callout)
          .foregroundStyle(record.state.needsVerification ? WorkbenchTheme.risk : .secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      if record.state.needsVerification {
        Text("结果未知，请核对远端结果后再重试。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.risk)
      }

      frozenPlanEvidence(record)
      eventEvidence(record)
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("发布执行：\(record.plan.package.title)"))
    .accessibilityValue(
      "\(localizedExecutionStateName(record.state))，\(record.createdAt.workbenchShortText)"
    )
    .accessibilityIdentifier("publish-execution-record-\(record.id)")
  }

  private func executionSummary(_ record: PublishExecutionRecord) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        localizedExecutionStateName(record.state), systemImage: executionStateImage(record.state)
      )
      .font(.callout.weight(.semibold))
      .foregroundStyle(record.state.needsVerification ? WorkbenchTheme.risk : .primary)
      Text(record.plan.package.title)
        .font(.callout)
        .lineLimit(2)
      Text(record.createdAt.workbenchShortText)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func verificationAction(
    _ record: PublishExecutionRecord,
    showsKeyboardShortcut: Bool
  ) -> some View {
    if record.state.needsVerification {
      if showsKeyboardShortcut {
        verificationButton(record)
          .keyboardShortcut("v", modifiers: [.command, .option])
      } else {
        verificationButton(record)
      }
    }
  }

  private func verificationButton(_ record: PublishExecutionRecord) -> some View {
    Button {
      verifyRemoteResult(record)
    } label: {
      Label(
        verifyingRecordID == record.id
          ? String(localized: "正在核对远端结果")
          : String(localized: "核对远端结果"),
        systemImage: "checkmark.shield"
      )
    }
    .buttonStyle(.bordered)
    .disabled(
      store.isQuickHideActive || store.isRemoteRepositoryPublishing || verifyingRecordID != nil
    )
    .help("只读取远端结果，不会写入远端；结果未知时请先核对再重试。")
    .accessibilityIdentifier("publish-execution-verify-\(record.id)")
    .accessibilityLabel("核对远端结果")
    .accessibilityHint("只读取远端结果，不会写入远端")
  }

  private func frozenPlanEvidence(_ record: PublishExecutionRecord) -> some View {
    DisclosureGroup(String(localized: "本次发布的目标与文件")) {
      VStack(alignment: .leading, spacing: 6) {
        evidenceRow(String(localized: "站点名"), record.plan.target.siteName)
        evidenceRow(String(localized: "仓库"), record.plan.target.repositoryName)
        evidenceRow(String(localized: "API 地址"), record.plan.target.apiBaseURL)
        evidenceRow(String(localized: "目标分支"), record.plan.target.targetBranch)
        evidenceRow(String(localized: "执行分支"), record.plan.branchName)
        evidenceRow(String(localized: "发布方式"), record.plan.target.mode.localizedDisplayName)

        if !record.plan.package.files.isEmpty {
          Text(String(localized: "文件列表"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
          ForEach(record.plan.package.files.map(\.repositoryPath), id: \.self) { path in
            WorkbenchPathIdentity(path: path)
          }
        }
      }
      .padding(.top, 6)
    }
    .font(.caption)
    .accessibilityIdentifier("publish-execution-plan-\(record.id)")
  }

  private func eventEvidence(_ record: PublishExecutionRecord) -> some View {
    DisclosureGroup(String(localized: "执行过程")) {
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(record.events.enumerated()), id: \.offset) { _, event in
          VStack(alignment: .leading, spacing: 2) {
            Text(event.stage.localizedDisplayName)
              .font(.caption.weight(.semibold))
            Text(event.date.workbenchShortText)
              .font(.workbenchMetadata.monospacedDigit())
              .foregroundStyle(.secondary)
            Text(event.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
        }
      }
      .padding(.top, 6)
    }
    .font(.caption)
    .accessibilityIdentifier("publish-execution-events-\(record.id)")
  }

  private func evidenceRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 58, alignment: .leading)
      Text(value)
        .textSelection(.enabled)
        .lineLimit(2)
    }
  }

  private func verifyRemoteResult(_ record: PublishExecutionRecord) {
    guard !store.isQuickHideActive, !store.isRemoteRepositoryPublishing,
      verifyingRecordID == nil
    else { return }
    verifyingRecordID = record.id
    Task { @MainActor in
      await store.verifyPublishExecution(record.id)
      if verifyingRecordID == record.id {
        verifyingRecordID = nil
      }
    }
  }

  private func executionStateImage(_ state: PublishExecutionState) -> String {
    switch state {
    case .awaitingRemoteResult:
      return "clock.badge.exclamationmark"
    case .needsVerification:
      return "questionmark.shield"
    case .remoteAccepted:
      return "checkmark.shield"
    case .verifiedUnchanged:
      return "arrow.uturn.backward.circle"
    }
  }

  private func localizedExecutionStateName(_ state: PublishExecutionState) -> String {
    switch state {
    case .awaitingRemoteResult:
      return CoreL10n.text("等待远端结果")
    case .needsVerification:
      return CoreL10n.text("待核实远端结果")
    case .remoteAccepted:
      return CoreL10n.text("远端已确认接收")
    case .verifiedUnchanged:
      return CoreL10n.text("已核实未写入")
    }
  }
}
