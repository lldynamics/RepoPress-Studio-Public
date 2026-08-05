import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceToolbarControlCluster<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 2) {
      content
    }
    .padding(2)
    .workbenchGlassSurface(
      material: .ultraThinMaterial,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
  }
}

struct WorkspaceToolbarMenuLabel: View {
  let title: String
  let systemImage: String
  let showsTitle: Bool
  var iconColor: Color = .secondary
  var siteKindDisplayName: String = ""

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
        .foregroundStyle(iconColor)
      if showsTitle {
        Text(title)
          .foregroundStyle(.primary)
          .workbenchTruncatedIdentity(title)
        if !siteKindDisplayName.isEmpty {
          Text(siteKindDisplayName)
            .font(.workbenchMetadata.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(.secondary)
        }
      }
    }
    .font(.caption.weight(.medium))
    .frame(minWidth: showsTitle ? nil : 28, minHeight: 24)
    .padding(.horizontal, showsTitle ? 6 : 0)
    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .accessibilityHidden(true)
  }
}

struct WorkspaceTaskCenterToolbarButton: View {
  @ObservedObject private var activityStatus: WorkbenchActivityStatusFacade
  let isCompact: Bool
  let action: () -> Void

  init(store: WorkbenchStore, isCompact: Bool, action: @escaping () -> Void) {
    _activityStatus = ObservedObject(wrappedValue: store.activityStatus)
    self.isCompact = isCompact
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Label("任务", systemImage: activityStatus.activeTaskCount > 0
        ? "list.bullet.rectangle.fill"
        : "list.bullet.rectangle")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: activityStatus.activeTaskCount > 0,
        showsTitle: !isCompact
      )
    )
    .overlay(alignment: .topTrailing) {
      if activityStatus.failedTaskCount > 0 {
        Text("\(min(activityStatus.failedTaskCount, 9))")
          .font(.workbenchMetadata.weight(.bold).monospacedDigit())
          .foregroundStyle(.white)
          .frame(minWidth: 14, minHeight: 14)
          .background(WorkbenchTheme.risk, in: Circle())
          .offset(x: 4, y: -4)
      }
    }
    .help(String(localized: "统一任务中心"))
    .accessibilityLabel("统一任务中心")
    .accessibilityValue(taskCenterAccessibilityValue)
    .accessibilityIdentifier("workspace-task-center-toggle")
  }

  private var taskCenterAccessibilityValue: String {
    if activityStatus.activeTaskCount == 0, activityStatus.failedTaskCount == 0 {
      return String(localized: "无进行中或失败任务")
    }
    return String(
      localized: "进行中 \(activityStatus.activeTaskCount)，失败 \(activityStatus.failedTaskCount)"
    )
  }
}

struct OmniCommandSearchBar: View {
  let isCompact: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        if !isCompact {
          Text("搜索草稿、标签与指令…")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 4)

        HStack(spacing: 2) {
          Text("⌘")
            .font(.workbenchMetadata.weight(.bold))
          Text("P")
            .font(.workbenchMetadata.weight(.bold))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 8)
      .frame(height: 26)
      .frame(minWidth: isCompact ? 70 : 180, maxWidth: 240)
      .workbenchGlassSurface(
        material: .ultraThinMaterial,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(String(localized: "唤起命令面板与全局搜索 (⌘P)"))
    .accessibilityLabel("全局搜索")
  }
}

struct WorkspaceToolbarIconButtonStyle: ButtonStyle {
  let isActive: Bool
  let showsTitle: Bool

  @Environment(\.isFocused) private var isFocused

  init(isActive: Bool, showsTitle: Bool = false) {
    self.isActive = isActive
    self.showsTitle = showsTitle
  }

  func makeBody(configuration: Configuration) -> some View {
    styledLabel(configuration.label)
      .font(.workbenchButtonLabel)
      .symbolVariant(isActive ? .fill : .none)
      .foregroundStyle(isActive ? WorkbenchTheme.navigationSelection : Color.secondary)
      .frame(minWidth: showsTitle ? nil : 28, minHeight: 28)
      .padding(.horizontal, showsTitle ? 8 : 6)
      .fixedSize(horizontal: showsTitle, vertical: false)
      .background {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(backgroundColor(isPressed: configuration.isPressed))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(
            isFocused ? Color.accentColor : Color.clear,
            lineWidth: isFocused ? 2 : 0
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }

  @ViewBuilder
  private func styledLabel(_ label: Configuration.Label) -> some View {
    if showsTitle {
      label.labelStyle(.titleAndIcon)
    } else {
      label.labelStyle(.iconOnly)
    }
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isPressed {
      return Color.primary.opacity(0.08)
    }
    if isActive {
      return WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground)
    }
    return .clear
  }
}

struct WorkspaceToolbarLeadingContent: View {
  let store: WorkbenchStore
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  let isCompact: Bool

  init(store: WorkbenchStore, isCompact: Bool) {
    self.store = store
    _shell = ObservedObject(wrappedValue: store.shell)
    self.isCompact = isCompact
  }

  var body: some View {
    WorkspaceToolbarControlCluster {
      Menu {
        ForEach(shell.publishingProfiles) { profile in
          Button {
            store.selectProfile(profile.id)
          } label: {
            if profile.id == shell.activeProfileID {
              Label(profile.name, systemImage: "checkmark")
            } else {
              Text(profile.name)
            }
          }
        }
      } label: {
        WorkspaceToolbarMenuLabel(
          title: shell.activeProfile.name,
          systemImage: "globe",
          showsTitle: !isCompact,
          siteKindDisplayName: shell.activeProfile.siteKind.localizedDisplayName
        )
        .frame(maxWidth: isCompact ? nil : 200, alignment: .leading)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help(
        String(
          localized: "个人网站：\(shell.activeProfile.name) · \(shell.activeProfile.siteKind.localizedDisplayName)"
        )
      )
      .accessibilityLabel("切换个人网站")
      .accessibilityValue(shell.activeProfile.name)
      .accessibilityIdentifier("workspace-profile-menu")

    }
  }
}

private enum PublishingStatusArea {
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
      return String(localized: "部署历史")
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
  let store: WorkbenchStore
  @ObservedObject private var statusState: WorkbenchPublishStatusFeatureFacade
  let canUseProtectedWorkbench: Bool
  let selectedDraftID: UUID?
  let openPublishFlow: () -> Void
  let openRepositoryOverview: () -> Void
  let openContentHealthOverview: () -> Void
  let openReleaseHistory: () -> Void
  @State private var isPresented = false
  @State private var syncAnimationTrigger = 0

  init(
    store: WorkbenchStore,
    canUseProtectedWorkbench: Bool,
    selectedDraftID: UUID?,
    openPublishFlow: @escaping () -> Void,
    openRepositoryOverview: @escaping () -> Void,
    openContentHealthOverview: @escaping () -> Void,
    openReleaseHistory: @escaping () -> Void
  ) {
    self.store = store
    _statusState = ObservedObject(wrappedValue: store.publishStatus)
    self.canUseProtectedWorkbench = canUseProtectedWorkbench
    self.selectedDraftID = selectedDraftID
    self.openPublishFlow = openPublishFlow
    self.openRepositoryOverview = openRepositoryOverview
    self.openContentHealthOverview = openContentHealthOverview
    self.openReleaseHistory = openReleaseHistory
  }

  var body: some View {
    let items = statusItems
    let currentToolbarStatus = items.max { $0.severity.rawValue < $1.severity.rawValue } ?? draftStatus

    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 6) {
        Circle()
          .fill(currentToolbarStatus.color)
          .frame(width: 7, height: 7)
        Text(currentToolbarStatus.value)
          .foregroundStyle(.primary)
      }
      .font(.workbenchButtonLabel)
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityLabel("发布状态")
      .padding(.horizontal, 9)
      .frame(height: 26)
      .background(currentToolbarStatus.color.opacity(0.12), in: Capsule())
      .overlay {
        Capsule()
          .stroke(currentToolbarStatus.color.opacity(0.2), lineWidth: 0.8)
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(!canUseProtectedWorkbench)
    .help(
      String(
        localized: "发布状态：\(currentToolbarStatus.area.title) · \(currentToolbarStatus.value)。点击查看状态和发布操作。"
      )
    )
    .accessibilityLabel("发布状态")
    .accessibilityValue("\(currentToolbarStatus.area.title)：\(currentToolbarStatus.value)")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 0) {
        Label("发布状态", systemImage: "paperplane.circle")
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

  private var statusItems: [PublishingStatusPopoverItem] {
    [repositoryStatus, draftStatus, deploymentStatus]
  }

  private var repositoryStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.repository
    if statusState.activeProfile.purpose.requiresRepositoryReadiness,
       statusState.activeProfile.localRepositoryRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    if !report.remoteChangedFiles.isEmpty {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "远端有 \(report.remoteChangedFiles.count) 项变化"),
        detail: String(localized: "同步前请审阅远端变更队列。"),
        statusImage: "arrow.down.doc",
        color: WorkbenchTheme.risk,
        severity: .error
      )
    }

    if !report.changedFiles.isEmpty {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "本地有 \(report.changedFiles.count) 项变化"),
        detail: String(localized: "发布前请审阅本地差异。"),
        statusImage: "arrow.triangle.2.circlepath",
        color: WorkbenchTheme.warning,
        severity: .warning
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: report.syncStatusTitle,
      detail: report.rootPath,
      statusImage: "checkmark.circle",
      color: WorkbenchTheme.success,
      severity: .ready
    )
  }

  private var draftStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.draft
    guard let draft = statusState.selectedDraft else {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "未选择文章"),
        detail: String(localized: "选择文章后可查看其发布检查状态。"),
        statusImage: "doc.badge.questionmark",
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
        severity: .error
      )
    }

    let warningCount = max(
      issues.filter { $0.severity == .warning }.count,
      statusState.localPublishReadiness?.warningIssues.count ?? 0
    )
    if warningCount > 0 {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "\(warningCount) 个待确认项"),
        detail: draft.title.nilIfEmpty ?? String(localized: "当前文章需要审阅发布提示。"),
        statusImage: "exclamationmark.triangle",
        color: WorkbenchTheme.warning,
        severity: .warning
      )
    }

    guard let readiness = statusState.localPublishReadiness,
          readiness.writeReadiness != .blocked,
          readiness.commitReadiness != .blocked else {
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

    if let failedEntry = entries.first(where: { $0.status == .failed || $0.status == .pendingRemoteRecovery || $0.status == .pendingRetry }) {
      return PublishingStatusPopoverItem(
        area: area,
        value: failedEntry.status.localizedDisplayName,
        detail: failedEntry.statusMessage,
        statusImage: failedEntry.status.systemImage,
        color: WorkbenchTheme.risk,
        severity: .error
      )
    }

    if let pendingEntry = entries.first(where: { $0.status == .pendingDeployment || $0.status == .deploying }) {
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
          if let blockingArea = publishBlockingItem?.area {
            openStatusArea(blockingArea)
          } else {
            openPublishFlow()
          }
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
          syncAnimationTrigger &+= 1
          openRepositoryOverview()
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
              .workbenchSyncSymbolEffect(trigger: syncAnimationTrigger)
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

  private var publishBlockingItem: PublishingStatusPopoverItem? {
    [repositoryStatus, draftStatus].first { $0.severity == .error }
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
