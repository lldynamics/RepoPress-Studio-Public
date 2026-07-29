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
    .background(
      WorkbenchBackgroundStyle.page,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    }
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

struct WorkspaceToolbarIconButton: View {
  let systemImage: String
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
    }
    .buttonStyle(.plain)
    .help(title)
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
          Text("K")
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
      .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
      }
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .buttonStyle(.plain)
    .help("唤起命令面板与全局搜索 (⌘K)")
    .accessibilityLabel("全局搜索")
  }
}

struct WorkspaceToolbarIconButtonStyle: ButtonStyle {
  let isActive: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(.iconOnly)
      .font(.system(size: 13, weight: .medium))
      .symbolVariant(isActive ? .fill : .none)
      .foregroundStyle(isActive ? WorkbenchTheme.navigationSelection : Color.secondary)
      .frame(width: 28, height: 24)
      .background {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(backgroundColor(isPressed: configuration.isPressed))
      }
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool

  var body: some View {
    WorkspaceToolbarControlCluster {
      Menu {
        ForEach(store.publishingProfiles) { profile in
          Button {
            store.selectProfile(profile.id)
          } label: {
            if profile.id == store.activeProfileID {
              Label(profile.name, systemImage: "checkmark")
            } else {
              Text(profile.name)
            }
          }
        }
      } label: {
        WorkspaceToolbarMenuLabel(
          title: store.activeProfile.name,
          systemImage: "globe",
          showsTitle: !isCompact,
          siteKindDisplayName: store.activeProfile.siteKind.localizedDisplayName
        )
        .frame(maxWidth: isCompact ? nil : 200, alignment: .leading)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("个人网站：\(store.activeProfile.name) · \(store.activeProfile.siteKind.localizedDisplayName)")
      .accessibilityLabel("切换个人网站")
      .accessibilityValue(store.activeProfile.name)
      .accessibilityIdentifier("workspace-profile-menu")

      LocalSitePreviewToolbarControl(store: store, isCompact: isCompact)
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
  @ObservedObject var store: WorkbenchStore
  let canUseProtectedWorkbench: Bool
  let selectedDraftID: UUID?
  let openPublishFlow: () -> Void
  let openRepositoryOverview: () -> Void
  let openContentHealthOverview: () -> Void
  let openReleaseHistory: () -> Void
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 6) {
        Circle()
          .fill(toolbarStatus.color)
          .frame(width: 7, height: 7)
        Text(toolbarStatus.value)
          .foregroundStyle(.primary)
      }
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .accessibilityLabel("发布状态")
      .padding(.horizontal, 9)
      .frame(height: 26)
      .background(toolbarStatus.color.opacity(0.12), in: Capsule())
      .overlay {
        Capsule()
          .stroke(toolbarStatus.color.opacity(0.2), lineWidth: 0.8)
      }
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
        value: String(localized: "未配置"),
        detail: String(localized: "当前站点尚未选择本地仓库。"),
        statusImage: "externaldrive.badge.questionmark",
        color: .secondary,
        severity: .pending
      )
    }

    guard let report = store.repositoryReport else {
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
    guard let draft = store.selectedDraft else {
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "未选择文章"),
        detail: String(localized: "选择文章后可查看其发布检查状态。"),
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
        value: String(localized: "\(blockingCount) 个阻断项"),
        detail: draft.title.nilIfEmpty ?? String(localized: "当前文章存在发布阻断项。"),
        statusImage: "xmark.octagon",
        color: WorkbenchTheme.risk,
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
        value: String(localized: "\(warningCount) 个待确认项"),
        detail: draft.title.nilIfEmpty ?? String(localized: "当前文章需要审阅发布提示。"),
        statusImage: "exclamationmark.triangle",
        color: WorkbenchTheme.warning,
        severity: .warning
      )
    }

    guard let readiness = store.localPublishReadiness,
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
    let entries = store.activeProfileReleaseLedger.entries
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
          if publishBlockingItem == nil {
            Label("发布当前文章…", systemImage: "paperplane")
          } else {
            Label("处理发布阻断项", systemImage: "exclamationmark.triangle")
          }
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
          Label(workspaceNavigationLocalizedKey("workspace.sync"), systemImage: "arrow.triangle.2.circlepath")
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
