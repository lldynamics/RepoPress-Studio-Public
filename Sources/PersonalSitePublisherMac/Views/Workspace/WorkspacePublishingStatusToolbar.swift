import Foundation
import PublishingWorkbenchCore
import SwiftUI

enum PublishingStatusArea {
  case repository
  case draft
  case deployment

  var title: String {
    switch self {
    case .repository:
      return String(localized: "仓库")
    case .draft:
      return String(localized: "当前文章")
    case .deployment:
      return String(localized: "发布历史")
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

struct PublishingStatusPopoverItem: Identifiable {
  let area: PublishingStatusArea
  let value: String
  let detail: String
  let statusImage: String
  let color: Color
  let severity: PublishingStatusSeverity
  var count: Int? = nil

  var id: String { area.title }
}

enum PublishingStatusSeverity: Int {
  case ready
  case pending
  case information
  case active
  case warning
  case error

  var symbol: String {
    switch self {
    case .ready:
      return "checkmark.circle.fill"
    case .pending:
      return "clock.fill"
    case .information:
      return "info.circle.fill"
    case .active:
      return "arrow.triangle.2.circlepath.circle.fill"
    case .warning:
      return "exclamationmark.triangle.fill"
    case .error:
      return "xmark.circle.fill"
    }
  }
}

struct PublishingStatusToolbarControl: View {
  let store: WorkbenchStore
  @ObservedObject private var statusState: WorkbenchPublishStatusFeatureFacade
  let selectedDraftID: UUID?
  let selectedSection: WorkspaceSection
  let isCompact: Bool
  let openPublishFlow: () -> Void
  let openRepositoryOverview: () -> Void
  let openContentHealthOverview: () -> Void
  let openReleaseHistory: () -> Void
  @State private var isPresented = false

  init(
    store: WorkbenchStore,
    selectedDraftID: UUID?,
    selectedSection: WorkspaceSection,
    isCompact: Bool,
    openPublishFlow: @escaping () -> Void,
    openRepositoryOverview: @escaping () -> Void,
    openContentHealthOverview: @escaping () -> Void,
    openReleaseHistory: @escaping () -> Void
  ) {
    self.store = store
    _statusState = ObservedObject(wrappedValue: store.publishStatus)
    self.selectedDraftID = selectedDraftID
    self.selectedSection = selectedSection
    self.isCompact = isCompact
    self.openPublishFlow = openPublishFlow
    self.openRepositoryOverview = openRepositoryOverview
    self.openContentHealthOverview = openContentHealthOverview
    self.openReleaseHistory = openReleaseHistory
  }

  var body: some View {
    let items = statusItems
    let currentToolbarStatus = contextualToolbarStatus

    Button {
      isPresented.toggle()
    } label: {
      statusToolbarLabel(currentToolbarStatus)
        .font(.workbenchButtonLabel)
        .accessibilityLabel(contextualStatusTitle)
        .padding(.horizontal, 8)
        .frame(
          minWidth: isCompact ? 30 : 96,
          maxWidth: isCompact ? nil : 200,
          minHeight: 28
        )
        .background(currentToolbarStatus.color.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle(cornerRadius: 13, lineWidth: 1.5))
    .help(
      String(
        localized: "\(contextualStatusTitle)：\(currentToolbarStatus.value)。点击查看状态和发布操作。"
      )
    )
    .accessibilityLabel(contextualStatusTitle)
    .accessibilityValue("\(currentToolbarStatus.area.title)：\(currentToolbarStatus.value)")
    .accessibilityIdentifier("workspace-publishing-status")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 0) {
        Label(contextualStatusTitle, systemImage: "paperplane.circle")
          .font(.headline)
          .padding(.horizontal, WorkbenchSpacing.section)
          .padding(.vertical, 12)

        Divider()

        ForEach(items) { item in
          Button {
            openStatusArea(item.area)
          } label: {
            statusRow(item)
          }
          .buttonStyle(.plain)
          if item.id != items.last?.id {
            Divider()
              .padding(.leading, WorkbenchSpacing.section)
          }
        }

        Divider()

        publishingActions
          .padding(WorkbenchSpacing.section)
      }
      .frame(width: 380)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("发布状态与操作")
    }
  }

  @ViewBuilder
  private func statusToolbarLabel(_ status: PublishingStatusPopoverItem) -> some View {
    HStack(spacing: 5) {
      Image(systemName: status.severity.symbol)
        .font(.system(size: isCompact ? 12 : 8, weight: .semibold))
        .foregroundStyle(status.color)
      if !isCompact {
        Text(status.value)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
      } else if let count = status.count {
        Text(count, format: .number)
          .monospacedDigit()
          .foregroundStyle(.primary)
          .fixedSize()
      }
    }
  }

  private var statusItems: [PublishingStatusPopoverItem] {
    switch selectedSection {
    case .sync:
      return [repositoryStatus, draftStatus, deploymentStatus]
    case .writing, .contentHealth:
      return [draftStatus, repositoryStatus, deploymentStatus]
    case .library, .rss, .images:
      return [draftStatus, repositoryStatus, deploymentStatus]
    }
  }

  private var contextualToolbarStatus: PublishingStatusPopoverItem {
    switch selectedSection {
    case .sync:
      return repositoryStatus
    case .writing, .contentHealth, .library, .rss, .images:
      return draftStatus
    }
  }

  private var contextualStatusTitle: String {
    switch selectedSection {
    case .sync:
      return String(localized: "站点状态")
    case .contentHealth:
      return String(localized: "检查状态")
    case .writing, .library, .rss, .images:
      return String(localized: "文章状态")
    }
  }

  /// The toolbar is rendered once per window, while `WorkbenchStore` keeps a
  /// shared compatibility selection for commands. Resolve the visible draft
  /// from the window's explicit identity and only borrow shared projections
  /// when they are demonstrably for that same draft/profile.
  private var explicitDraft: ArticleDraft? {
    selectedDraftID.flatMap(store.draft(for:))
  }

  private var explicitDraftProfile: SiteProfile? {
    explicitDraft.map(store.profile(for:))
  }

  private var windowDraftUsesActiveProfile: Bool {
    guard let explicitDraftProfile else { return true }
    return explicitDraftProfile.id == statusState.activeProfile.id
  }

  private var sharedDraftProjectionMatchesExplicitDraft: Bool {
    guard let explicitDraft,
      let explicitDraftProfile,
      statusState.selectedDraftID == explicitDraft.id
    else {
      return false
    }
    return statusState.activeProfile.id == explicitDraftProfile.id
  }

  private var repositoryStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.repository
    if !windowDraftUsesActiveProfile {
      let profileName = explicitDraftProfile?.name ?? String(localized: "其他站点")
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "未激活"),
        detail: String(localized: "窗口文章属于“\(profileName)”，当前站点状态未套用。"),
        statusImage: "externaldrive.badge.questionmark",
        color: .secondary,
        severity: .pending
      )
    }

    if statusState.activeProfile.purpose.requiresRepositoryReadiness,
      statusState.activeProfile.localRepositoryRootPath.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
    {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "未配置"),
        detail: String(localized: "当前站点尚未选择本地仓库。"),
        statusImage: "externaldrive.badge.questionmark",
        color: .secondary,
        severity: .pending
      )
    }

    guard let report = statusState.repositoryReport else {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "待扫描"),
        detail: String(localized: "尚未读取当前仓库状态。"),
        statusImage: "arrow.clockwise",
        color: .secondary,
        severity: .pending
      )
    }

    switch WorkspaceTopBarPresentation.repositoryScanStatus(for: report) {
    case .missingGitDirectory:
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "未发现 Git 仓库"),
        detail: String(localized: "当前目录不是 Git 工作树，diff 和提交入口暂不可用。"),
        statusImage: "exclamationmark.triangle",
        color: WorkbenchTheme.warning,
        severity: .warning
      )
    case .blockingIssues(let count):
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "仓库有 \(count) 个阻断项"),
        detail: String(localized: "请在站点概览中处理仓库问题。"),
        statusImage: "xmark.octagon",
        color: WorkbenchTheme.risk,
        severity: .error,
        count: count
      )
    case .remoteChanges(let count):
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "远端有 \(count) 项变化"),
        detail: String(localized: "同步前请审阅远端变更队列。"),
        statusImage: "arrow.down.doc",
        color: WorkbenchTheme.info,
        severity: .information,
        count: count
      )
    case .localChanges(let count):
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "本地有 \(count) 项变化"),
        detail: String(localized: "发布前请审阅本地差异。"),
        statusImage: "arrow.triangle.2.circlepath",
        color: WorkbenchTheme.warning,
        severity: .warning,
        count: count
      )
    case .ready:
      return PublishingStatusPopoverItem(
        area: area,
        value: report.syncStatusTitle,
        detail: report.rootPath,
        statusImage: "checkmark.circle",
        color: WorkbenchTheme.success,
        severity: .ready
      )
    }
  }

  var draftStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.draft
    guard let draft = explicitDraft else {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "未选择文章"),
        detail: String(localized: "选择文章后可查看其发布检查状态。"),
        statusImage: "doc.badge.questionmark",
        color: .secondary,
        severity: .pending
      )
    }

    if draft.isGeneralDraft {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "通用草稿，未绑定站点"),
        detail: String(localized: "可继续编辑；绑定站点后才会检查发布条件。"),
        statusImage: "doc.text",
        color: .secondary,
        severity: .information
      )
    }

    // A shared preflight/readiness projection belongs to the compatibility
    // selection. Never show it for a background window's other draft.
    guard sharedDraftProjectionMatchesExplicitDraft else {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "待运行检查"),
        detail: draft.title.nilIfEmpty ?? String(localized: "请运行发布前检查。"),
        statusImage: "checklist",
        color: .secondary,
        severity: .pending
      )
    }

    let issues = statusState.preflightIssues
    let blockingCount = max(
      issues.filter { $0.severity == .error }.count,
      statusState.localPublishReadiness?.blockingIssueCount ?? 0
    )
    if blockingCount > 0 {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "\(blockingCount) 个阻断项"),
        detail: draft.title.nilIfEmpty ?? String(localized: "当前文章存在发布阻断项。"),
        statusImage: "xmark.octagon",
        color: WorkbenchTheme.risk,
        severity: .error,
        count: blockingCount
      )
    }

    let warningCount = max(
      issues.filter { $0.severity == .warning }.count,
      statusState.localPublishReadiness?.warningIssues.count ?? 0
    )
    if warningCount > 0 {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "\(warningCount) 个文章警告"),
        detail: draft.title.nilIfEmpty ?? String(localized: "当前文章需要审阅发布提示。"),
        statusImage: "exclamationmark.triangle",
        color: WorkbenchTheme.warning,
        severity: .warning,
        count: warningCount
      )
    }

    guard let readiness = statusState.localPublishReadiness,
      readiness.writeReadiness != .blocked,
      readiness.commitReadiness != .blocked
    else {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "待运行检查"),
        detail: draft.title.nilIfEmpty ?? String(localized: "请运行发布前检查。"),
        statusImage: "checklist",
        color: .secondary,
        severity: .pending
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: String(localized: "检查通过"),
      detail: draft.title.nilIfEmpty ?? String(localized: "当前文章已具备写入和提交条件。"),
      statusImage: "checkmark.circle",
      color: WorkbenchTheme.success,
      severity: .ready
    )
  }

  private var deploymentStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.deployment
    if !windowDraftUsesActiveProfile {
      let profileName = explicitDraftProfile?.name ?? String(localized: "其他站点")
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "未激活"),
        detail: String(localized: "窗口文章属于“\(profileName)”，当前站点发布记录未套用。"),
        statusImage: "clock.badge.questionmark",
        color: .secondary,
        severity: .pending
      )
    }

    let entries = statusState.activeProfileReleaseLedger.entries
    guard !entries.isEmpty else {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "暂无发布记录"),
        detail: String(localized: "远端发布后会在这里显示部署检查结果。"),
        statusImage: "clock",
        color: .secondary,
        severity: .pending
      )
    }

    if let failedEntry = entries.first(where: {
      $0.status == .failed || $0.status == .pendingRemoteRecovery || $0.status == .pendingRetry
    }) {
      return PublishingStatusPopoverItem(
        area: area,
        value: failedEntry.status.localizedDisplayName,
        detail: failedEntry.statusMessage,
        statusImage: failedEntry.status.systemImage,
        color: WorkbenchTheme.risk,
        severity: .error
      )
    }

    if let pendingEntry = entries.first(where: {
      $0.status == .pendingDeployment || $0.status == .deploying
    }) {
      return PublishingStatusPopoverItem(
        area: area,
        value: pendingEntry.status.localizedDisplayName,
        detail: pendingEntry.statusMessage,
        statusImage: pendingEntry.status.systemImage,
        color: WorkbenchTheme.progress,
        severity: .active
      )
    }

    if let latestEntry = entries.first {
      return PublishingStatusPopoverItem(
        area: area,
        value: latestEntry.status.localizedDisplayName,
        detail: latestEntry.statusMessage,
        statusImage: latestEntry.status.systemImage,
        color: latestEntry.status == .succeeded ? WorkbenchTheme.success : .secondary,
        severity: latestEntry.status == .succeeded ? .ready : .pending
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: String(localized: "待检查"),
      detail: String(localized: "尚未记录部署检查结果。"),
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
          Label("准备发布", systemImage: "paperplane")
        }
        .workbenchProminentActionStyle()
        .disabled(selectedDraftID == nil)

        Button {
          isPresented = false
          store.runPreflight()
          openContentHealthOverview()
        } label: {
          Label("运行检查", systemImage: "checklist")
        }
        .buttonStyle(.bordered)
      }

      HStack(spacing: 14) {
        Button {
          isPresented = false
          openRepositoryOverview()
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(workspaceNavigationLocalizedKey("workspace.sync"))
          }
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
      openRepositoryOverview()
    case .draft:
      store.runPreflight()
      openContentHealthOverview()
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

        Text(item.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }

    }
    .padding(.horizontal, WorkbenchSpacing.section)
    .padding(.vertical, 11)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.area.title)
    .accessibilityValue(item.value)
  }

}
