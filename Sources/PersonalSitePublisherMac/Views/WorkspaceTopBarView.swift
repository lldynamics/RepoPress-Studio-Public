import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceToolbarLeadingContent: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool

  private var profileSelection: Binding<UUID> {
    Binding(
      get: { store.activeProfileID },
      set: { store.selectProfile($0) }
    )
  }

  var body: some View {
    HStack(spacing: 8) {
      Picker("站点", selection: profileSelection) {
        ForEach(store.profiles) { profile in
          Text(profile.name).tag(profile.id)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: isCompact ? 140 : 170)
      .help("当前站点：\(store.activeProfile.name) · \(store.activeProfile.siteKind.localizedDisplayName)")
      .accessibilityLabel("当前站点 Profile")
      .accessibilityValue(store.activeProfile.name)

      LocalSitePreviewToolbarControl(store: store, isCompact: isCompact)
    }
  }
}

struct WorkspaceToolbarTitle: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    Label(sectionTitleKey, systemImage: sectionSystemImage)
      .font(.headline)
      .lineLimit(1)
      .help(workspaceNavigationLocalizedString(sectionTitleKeyString))
      .accessibilityLabel(sectionTitleKey)
  }

  private var sectionTitleKey: LocalizedStringKey {
    workspaceNavigationLocalizedKey(sectionTitleKeyString)
  }

  private var sectionTitleKeyString: String {
    WorkspaceNavigationItem(section: store.selectedSection).displayNameLocalizationKey
  }

  private var sectionSystemImage: String {
    WorkspaceNavigationItem(section: store.selectedSection).systemImage
  }
}

private enum PublishingStatusArea {
  case repository
  case draft
  case deployment

  var title: String {
    switch self {
    case .repository:
      return "仓库"
    case .draft:
      return "当前文章"
    case .deployment:
      return "部署历史"
    }
  }

  var systemImage: String {
    switch self {
    case .repository:
      return "externaldrive"
    case .draft:
      return "doc.text"
    case .deployment:
      return "clock.arrow.circlepath"
    }
  }

}

private struct PublishingStatusPopoverItem: Identifiable {
  let area: PublishingStatusArea
  let value: String
  let detail: String
  let statusImage: String
  let color: Color
  let severity: PublishingStatusSeverity

  var id: String { area.title }
}

private enum PublishingStatusSeverity: Int {
  case ready
  case pending
  case active
  case warning
  case error
}

struct PublishingStatusToolbarControl: View {
  @ObservedObject var store: WorkbenchStore
  let canUseProtectedWorkbench: Bool
  let selectedDraftID: UUID?
  let openPublishFlow: () -> Void
  let openReleaseHistory: () -> Void
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Label(toolbarStatus.value, systemImage: toolbarStatus.statusImage)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(toolbarStatus.color)
        .lineLimit(1)
        .accessibilityLabel("发布状态")
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(WorkbenchBackgroundStyle.badge, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(!canUseProtectedWorkbench)
    .help("发布状态：\(toolbarStatus.area.title) · \(toolbarStatus.value)。点击查看状态和发布操作。")
    .accessibilityLabel("发布状态")
    .accessibilityValue("\(toolbarStatus.area.title)：\(toolbarStatus.value)")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 0) {
        Label("发布状态", systemImage: "paperplane.circle")
          .font(.headline)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)

        Divider()

        ForEach(statusItems) { item in
          Button {
            openStatusArea(item.area)
          } label: {
            statusRow(item)
          }
          .buttonStyle(.plain)
          if item.id != statusItems.last?.id {
            Divider()
              .padding(.leading, 14)
          }
        }

        Divider()

        publishingActions
          .padding(14)
      }
      .frame(width: 380)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("发布状态与操作")
    }
  }

  private var statusItems: [PublishingStatusPopoverItem] {
    [repositoryStatus, draftStatus, deploymentStatus]
  }

  private var toolbarStatus: PublishingStatusPopoverItem {
    statusItems.max { $0.severity.rawValue < $1.severity.rawValue } ?? draftStatus
  }

  private var repositoryStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.repository
    if store.activeProfile.purpose.requiresRepositoryReadiness,
       store.activeProfile.localRepositoryRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return PublishingStatusPopoverItem(
        area: area,
        value: "未配置",
        detail: "当前站点尚未选择本地仓库。",
        statusImage: "externaldrive.badge.questionmark",
        color: .secondary,
        severity: .pending
      )
    }

    guard let report = store.repositoryReport else {
      return PublishingStatusPopoverItem(
        area: area,
        value: "待扫描",
        detail: "尚未读取当前仓库状态。",
        statusImage: "arrow.clockwise",
        color: .secondary,
        severity: .pending
      )
    }

    if !report.remoteChangedFiles.isEmpty {
      return PublishingStatusPopoverItem(
        area: area,
        value: "远端有 \(report.remoteChangedFiles.count) 项变化",
        detail: "同步前请审阅远端变更队列。",
        statusImage: "arrow.down.doc",
        color: .red,
        severity: .error
      )
    }

    if !report.changedFiles.isEmpty {
      return PublishingStatusPopoverItem(
        area: area,
        value: "本地有 \(report.changedFiles.count) 项变化",
        detail: "发布前请审阅本地 Diff。",
        statusImage: "arrow.triangle.2.circlepath",
        color: .orange,
        severity: .warning
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: report.syncStatusTitle,
      detail: report.rootPath,
      statusImage: "checkmark.circle",
      color: .green,
      severity: .ready
    )
  }

  private var draftStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.draft
    guard let draft = store.selectedDraft else {
      return PublishingStatusPopoverItem(
        area: area,
        value: "未选择文章",
        detail: "选择文章后可查看其发布检查状态。",
        statusImage: "doc.badge.questionmark",
        color: .secondary,
        severity: .pending
      )
    }

    let issues = store.preflightIssues
    let blockingCount = max(
      issues.filter { $0.severity == .error }.count,
      store.localPublishReadiness?.blockingIssueCount ?? 0
    )
    if blockingCount > 0 {
      return PublishingStatusPopoverItem(
        area: area,
        value: "\(blockingCount) 个阻断项",
        detail: draft.title.nilIfEmpty ?? "当前文章存在发布阻断项。",
        statusImage: "xmark.octagon",
        color: .red,
        severity: .error
      )
    }

    let warningCount = max(
      issues.filter { $0.severity == .warning }.count,
      store.localPublishReadiness?.warningIssues.count ?? 0
    )
    if warningCount > 0 {
      return PublishingStatusPopoverItem(
        area: area,
        value: "\(warningCount) 个待确认项",
        detail: draft.title.nilIfEmpty ?? "当前文章需要审阅发布提示。",
        statusImage: "exclamationmark.triangle",
        color: .orange,
        severity: .warning
      )
    }

    guard let readiness = store.localPublishReadiness,
          readiness.writeReadiness != .blocked,
          readiness.commitReadiness != .blocked else {
      return PublishingStatusPopoverItem(
        area: area,
        value: "待运行检查",
        detail: draft.title.nilIfEmpty ?? "请运行发布前检查。",
        statusImage: "checklist",
        color: .secondary,
        severity: .pending
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: "检查通过",
      detail: draft.title.nilIfEmpty ?? "当前文章已具备写入和提交条件。",
      statusImage: "checkmark.circle",
      color: .green,
      severity: .ready
    )
  }

  private var deploymentStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.deployment
    let entries = store.activeProfileReleaseLedger.entries
    guard !entries.isEmpty else {
      return PublishingStatusPopoverItem(
        area: area,
        value: "暂无发布记录",
        detail: "远端发布后会在这里显示部署检查结果。",
        statusImage: "clock",
        color: .secondary,
        severity: .pending
      )
    }

    if let failedEntry = entries.first(where: { $0.status == .failed || $0.status == .pendingRemoteRecovery || $0.status == .pendingRetry }) {
      return PublishingStatusPopoverItem(
        area: area,
        value: failedEntry.status.localizedDisplayName,
        detail: failedEntry.statusMessage,
        statusImage: failedEntry.status.systemImage,
        color: .red,
        severity: .error
      )
    }

    if let pendingEntry = entries.first(where: { $0.status == .pendingDeployment || $0.status == .deploying }) {
      return PublishingStatusPopoverItem(
        area: area,
        value: pendingEntry.status.localizedDisplayName,
        detail: pendingEntry.statusMessage,
        statusImage: pendingEntry.status.systemImage,
        color: .blue,
        severity: .active
      )
    }

    if let latestEntry = entries.first {
      return PublishingStatusPopoverItem(
        area: area,
        value: latestEntry.status.localizedDisplayName,
        detail: latestEntry.statusMessage,
        statusImage: latestEntry.status.systemImage,
        color: latestEntry.status == .succeeded ? .green : .secondary,
        severity: latestEntry.status == .succeeded ? .ready : .pending
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: "待检查",
      detail: "尚未记录部署检查结果。",
      statusImage: "clock",
      color: .secondary,
      severity: .pending
    )
  }

  private var publishingActions: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Button {
          isPresented = false
          openPublishFlow()
        } label: {
          Label("发布当前文章…", systemImage: "paperplane")
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedDraftID == nil)

        Button {
          isPresented = false
          store.runPreflight()
          store.selectSection(.contentHealth)
        } label: {
          Label("运行检查", systemImage: "checklist")
        }
        .buttonStyle(.bordered)
      }

      HStack(spacing: 14) {
        Button {
          isPresented = false
          store.selectSection(.sync)
        } label: {
          Label("仓库与批量发布", systemImage: "arrow.triangle.2.circlepath")
        }

        Button {
          isPresented = false
          openReleaseHistory()
        } label: {
          Label("发布历史", systemImage: "clock.arrow.circlepath")
        }
      }
      .buttonStyle(.link)
    }
  }

  private func openStatusArea(_ area: PublishingStatusArea) {
    isPresented = false
    switch area {
    case .repository:
      store.selectSection(.sync)
    case .draft:
      store.runPreflight()
      store.selectSection(.contentHealth)
    case .deployment:
      openReleaseHistory()
    }
  }

  private func statusRow(_ item: PublishingStatusPopoverItem) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: item.area.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 3) {
        Text(item.area.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Label(item.value, systemImage: item.statusImage)
          .font(.callout.weight(.medium))
          .foregroundStyle(item.color)
          .lineLimit(1)

        Text(item.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }

    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.area.title)
    .accessibilityValue(item.value)
  }

}

private extension ReleaseLedgerEntry {
  @MainActor
  func matchesActiveProfile(_ store: WorkbenchStore) -> Bool {
    record.siteProfileID == nil || record.siteProfileID == store.activeProfileID
  }
}
