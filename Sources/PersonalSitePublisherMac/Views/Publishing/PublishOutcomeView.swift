import PublishingWorkbenchCore
import SwiftUI

/// What happened after a publish action: pushed, nothing to do, or stopped.
/// A pushed commit can be followed up with a deployment check right here.
struct PublishOutcomeView: View {
  let store: WorkbenchStore
  @ObservedObject private var observation: WorkbenchReleaseHistoryObservationFacade
  let outcome: WorkspacePublishSession.Outcome
  let isBusy: Bool
  let retryPushAction: () -> Void
  let openHistoryAction: () -> Void
  let dismissAction: () -> Void
  @State private var isCheckingDeployment = false

  init(
    store: WorkbenchStore, outcome: WorkspacePublishSession.Outcome, isBusy: Bool,
    retryPushAction: @escaping () -> Void, openHistoryAction: @escaping () -> Void,
    dismissAction: @escaping () -> Void
  ) {
    self.store = store
    self.outcome = outcome
    self.isBusy = isBusy
    self.retryPushAction = retryPushAction
    self.openHistoryAction = openHistoryAction
    self.dismissAction = dismissAction
    _observation = ObservedObject(wrappedValue: store.releaseHistoryObservation)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: symbol)
          .font(.workbenchTitle2)
          .foregroundStyle(color)
        VStack(alignment: .leading, spacing: 6) {
          Text(title)
            .font(.workbenchHeadline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
          Text(outcome.message)
            .font(.workbenchBody)
            .foregroundStyle(.workbenchSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(outcome.message)
            .accessibilityIdentifier("publish-outcome-message")
        }
      }
      .padding(WorkbenchSpacing.spacious)

      if let record {
        Divider()
        deploymentSection(record)
          .padding(WorkbenchSpacing.spacious)
      }

      Divider()
      HStack(spacing: 12) {
        if outcome.offersPushRetry {
          Button("核对或重新推送…", action: retryPushAction)
            .disabled(isBusy)
            .help("先只读核对之前的推送结果；仍有未推送的提交时再确认推送")
            .accessibilityIdentifier("publish-outcome-retry-push")
        }
        if record != nil {
          Button("查看发布历史", action: openHistoryAction)
            .accessibilityIdentifier("publish-outcome-open-history")
        }
        Spacer()
        Button(record?.articlePublishTrackingRequest == nil ? "完成" : "继续写作", action: dismissAction)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("publish-outcome-done")
      }
      .padding(WorkbenchSpacing.spacious)
    }
    .frame(minWidth: 460, idealWidth: 520)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-outcome")
  }

  private var record: ReleaseRecord? {
    outcome.recordID.flatMap { id in store.releaseRecords.first { $0.id == id } }
  }

  private var title: String {
    if let progress = trackingProgress {
      return progress.title
    }
    switch outcome.status {
    case .success: return String(localized: "已推送")
    case .information: return String(localized: "无需发布")
    case .inProgress: return String(localized: "正在发布")
    case .warning, .failure: return String(localized: "发布没有完成")
    }
  }

  private var symbol: String {
    if let phase = trackingProgress?.phase {
      switch phase {
      case .waitingForDeployment: return "hourglass"
      case .verifyingArticle: return "doc.text.magnifyingglass"
      case .online: return "checkmark.circle.fill"
      case .needsAttention: return "exclamationmark.triangle.fill"
      }
    }
    switch outcome.status {
    case .success: return "checkmark.circle.fill"
    case .information, .inProgress: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .failure: return "xmark.octagon.fill"
    }
  }

  private var color: Color {
    if let phase = trackingProgress?.phase {
      switch phase {
      case .waitingForDeployment, .verifyingArticle: return .secondary
      case .online: return WorkbenchTheme.success
      case .needsAttention: return WorkbenchTheme.warning
      }
    }
    switch outcome.status {
    case .success: return WorkbenchTheme.success
    case .information, .inProgress: return .secondary
    case .warning: return WorkbenchTheme.warning
    case .failure: return WorkbenchTheme.risk
    }
  }

  private var trackingProgress: ArticlePublishProgress? {
    record.flatMap { store.articlePublishProgress(for: $0) }
  }

  @ViewBuilder
  private func deploymentSection(_ record: ReleaseRecord) -> some View {
    if record.articlePublishTrackingRequest != nil {
      ArticlePublishProgressView(
        store: store, recordID: record.id, identifier: "publish-outcome-tracking")
    } else {
      legacyDeploymentSection(record)
    }
  }

  private func legacyDeploymentSection(_ record: ReleaseRecord) -> some View {
    let status = store.deploymentStatusSnapshot(for: record)
    return VStack(alignment: .leading, spacing: 8) {
      Text("\(record.branchName ?? "") · \(record.shortCommitSHA ?? "")")
        .font(.workbenchMetadata.monospaced())
        .foregroundStyle(.workbenchSecondary)
        .textSelection(.enabled)
      if let status, status.releaseRecordID == record.id {
        Label(status.title, systemImage: status.level.systemImage)
          .font(.workbenchBody.weight(.medium))
        Text(status.message)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      } else {
        Text("网站部署通常需要几分钟，之后可以检查文章是否已经上线。")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ReleaseArticleVerificationRows(store: store, record: record, snapshot: status)
      HStack {
        Button("检查部署与页面") {
          isCheckingDeployment = true
          Task {
            _ = await store.refreshDeploymentStatus(for: record)
            isCheckingDeployment = false
          }
        }
        .disabled(!store.canCheckDeploymentStatus(for: record) || isCheckingDeployment)
        .help(store.deploymentStatusReadiness(for: record).nextStep)
        .accessibilityIdentifier("publish-result-check-deployment")
        if isCheckingDeployment {
          ProgressView().controlSize(.small)
        }
      }
      if !store.canCheckDeploymentStatus(for: record) {
        Text(store.deploymentStatusReadiness(for: record).nextStep)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityIdentifier("publish-worktree-result")
  }
}

/// Both the live result and release history observe the same durable task.
struct ArticlePublishProgressView: View {
  let store: WorkbenchStore
  let recordID: UUID
  var identifier = "release-article-publish-tracking"
  @ObservedObject private var observation: WorkbenchReleaseHistoryObservationFacade
  @State private var isRechecking = false

  init(
    store: WorkbenchStore, recordID: UUID, identifier: String = "release-article-publish-tracking"
  ) {
    self.store = store
    self.recordID = recordID
    self.identifier = identifier
    _observation = ObservedObject(wrappedValue: store.releaseHistoryObservation)
  }

  var body: some View {
    if let record = store.releaseRecords.first(where: { $0.id == recordID }),
      let progress = store.articlePublishProgress(for: record)
    {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
        HStack {
          if progress.isPending { ProgressView().controlSize(.small) }
          Image(systemName: progressSymbol(for: progress.phase))
            .foregroundStyle(progressColor(for: progress.phase))
          Text(progress.title)
            .font(.workbenchBody.weight(.semibold))
            .foregroundStyle(progressColor(for: progress.phase))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progress.title)
            .accessibilityIdentifier("\(identifier)-status")
        }
        Text(progress.message)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(progress.message)
          .accessibilityIdentifier("\(identifier)-message")
        if progress.phase == .needsAttention {
          Button("重新检查上线") {
            isRechecking = true
            Task { @MainActor in
              await store.recheckArticlePublication(record)
              isRechecking = false
            }
          }
          .disabled(isRechecking || !store.canRecheckArticlePublication(record))
          .accessibilityIdentifier("\(identifier)-recheck")
        }
        if progress.phase == .online, let articleURL = verifiedArticleURL(for: record) {
          Button {
            ExternalURLOpener.open(articleURL)
          } label: {
            Label("打开已核验文章", systemImage: "arrow.up.right.square")
          }
          .buttonStyle(.bordered)
          .help("打开已核验的文章页面")
          .accessibilityIdentifier("\(identifier)-open-article")
        }
        DisclosureGroup("部署与文章版本详情") {
          ReleaseArticleVerificationRows(
            store: store, record: record,
            snapshot: record.articlePublishTrackingRequest?.completedSnapshot
              ?? store.deploymentStatusSnapshot(for: record))
        }
        .font(.workbenchMetadata)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(
        identifier == "release-article-publish-tracking" ? identifier : "\(identifier)-progress")
    }
  }

  private func progressSymbol(for phase: ArticlePublishProgress.Phase) -> String {
    switch phase {
    case .waitingForDeployment: return "hourglass"
    case .verifyingArticle: return "doc.text.magnifyingglass"
    case .online: return "checkmark.circle.fill"
    case .needsAttention: return "exclamationmark.triangle.fill"
    }
  }

  private func progressColor(for phase: ArticlePublishProgress.Phase) -> Color {
    switch phase {
    case .waitingForDeployment, .verifyingArticle: return .secondary
    case .online: return WorkbenchTheme.success
    case .needsAttention: return WorkbenchTheme.warning
    }
  }

  private func verifiedArticleURL(for record: ReleaseRecord) -> URL? {
    let target =
      record.articleVerificationTargets.first { $0.draftID == record.draftID }
      ?? record.articleVerificationTargets.first
    guard let text = target?.publicURLText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return nil }
    return URL(string: text)
  }
}

/// Article checks that stop "发布这篇" before anything is written. Each issue
/// jumps to where it can be fixed; nothing here publishes.
struct PublishBlockersView: View {
  let blockers: WorkspacePublishSession.Blockers
  let navigate: (PublishReadinessTarget) -> Void
  let dismissAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "xmark.octagon.fill")
          .font(.workbenchTitle2)
          .foregroundStyle(WorkbenchTheme.risk)
        VStack(alignment: .leading, spacing: 4) {
          Text(
            String(
              format: String(localized: "发布前需要处理 %d 个问题"), blockers.issues.count)
          )
          .font(.workbenchHeadline)
          Text(blockers.title)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .lineLimit(1)
        }
      }
      .padding(WorkbenchSpacing.spacious)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(items) { item in
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                  .font(.workbenchBody.weight(.semibold))
                Text(item.message)
                  .font(.workbenchMetadata)
                  .foregroundStyle(.workbenchSecondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 8)
              Button(item.actionTitle) { navigate(item.target) }
                .buttonStyle(.link)
            }
            Divider()
          }
        }
        .padding(WorkbenchSpacing.spacious)
      }
      .frame(maxHeight: 360)
      Divider()
      HStack {
        Text("处理后再点一次“发布这篇”。")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
        Spacer()
        Button("关闭", action: dismissAction)
          .keyboardShortcut(.defaultAction)
      }
      .padding(WorkbenchSpacing.spacious)
    }
    .frame(minWidth: 460, idealWidth: 520)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-blockers")
  }

  private var items: [PublishDrawerReadinessIssue] {
    PublishReadinessIssueGrouping.coalesced(blockers.issues).map {
      PublishDrawerReadinessIssue.preflight($0, draftID: blockers.draftID, prefix: "blocker")
    }
  }
}
