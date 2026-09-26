import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// Values used to keep the native toolbar readable while the workspace moves
/// through its three supported window-width bands. Keeping this presentation
/// policy independent of `ContentView` lets every toolbar placement use the
/// same visual language without observing editor state from the toolbar.
enum WorkspaceTopBarPresentation {
  enum Density: Equatable {
    case expanded
    case compact
    case minimal
  }

  struct PreviewAvailability: Equatable {
    enum DefaultAction: Equatable {
      case browser
      case inApp
      case unavailable
    }

    let isLivePreviewEnabled: Bool
    let isLivePreviewRunning: Bool
    let isBrowserPreviewEnabled: Bool

    var defaultAction: DefaultAction {
      if isBrowserPreviewEnabled { return .browser }
      if isLivePreviewEnabled { return .inApp }
      return .unavailable
    }

    var accessibilityValue: String {
      switch defaultAction {
      case .browser: return String(localized: "在浏览器中预览当前文章")
      case .inApp:
        return isLivePreviewRunning ? String(localized: "正在运行") : String(localized: "准备就绪")
      case .unavailable: return String(localized: "不可用")
      }
    }
  }

  enum SidebarVisibility: Equatable {
    case visible
    case hidden

    var title: String {
      switch self {
      case .visible: return String(localized: "隐藏侧栏")
      case .hidden: return String(localized: "显示侧栏")
      }
    }

    var accessibilityValue: String {
      switch self {
      case .visible: return String(localized: "侧栏已显示")
      case .hidden: return String(localized: "侧栏已隐藏")
      }
    }
  }

  static let expandedMinimumWidth: CGFloat = 1_180
  static let compactMinimumWidth: CGFloat = 960

  static func density(for workspaceWidth: CGFloat) -> Density {
    if workspaceWidth >= expandedMinimumWidth {
      return .expanded
    }
    if workspaceWidth >= compactMinimumWidth {
      return .compact
    }
    return .minimal
  }

  static func searchWidth(for density: Density) -> CGFloat {
    switch density {
    case .expanded: 340
    case .compact: 216
    case .minimal: 32
    }
  }

  /// The toolbar may only report a healthy repository after every blocking
  /// condition in the scan has been ruled out. Order matters: a missing Git
  /// directory makes change counts meaningless, and blocking issues outrank
  /// pending local or remote changes.
  enum RepositoryScanStatus: Equatable {
    case missingGitDirectory
    case blockingIssues(count: Int)
    case remoteChanges(count: Int)
    case localChanges(count: Int)
    case ready
  }

  static func repositoryScanStatus(for report: RepositoryScanReport) -> RepositoryScanStatus {
    guard report.hasGitDirectory else { return .missingGitDirectory }
    let blockingCount = report.preflightIssues.filter { $0.severity == .error }.count
    if blockingCount > 0 { return .blockingIssues(count: blockingCount) }
    if !report.remoteChangedFiles.isEmpty {
      return .remoteChanges(count: report.remoteChangedFiles.count)
    }
    if !report.changedFiles.isEmpty { return .localChanges(count: report.changedFiles.count) }
    return .ready
  }
}

extension WorkspaceSection {
  var showsPublishingStatusToolbar: Bool {
    switch self {
    case .writing, .sync, .contentHealth:
      return true
    case .library, .rss, .images:
      return false
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
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(.secondary)
        }
      }
    }
    .font(.workbenchButtonLabel)
    .frame(minWidth: showsTitle ? nil : 28, minHeight: 24)
    .padding(.horizontal, showsTitle ? 6 : 0)
    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .accessibilityHidden(true)
  }
}

struct WorkspaceTaskCenterToolbarButton: View {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var activityStatus: WorkbenchActivityStatusFacade
  let store: WorkbenchStore
  let isCompact: Bool
  @State private var isPresented = false

  init(store: WorkbenchStore, isCompact: Bool) {
    self.store = store
    _activityStatus = ObservedObject(wrappedValue: store.activityStatus)
    self.isCompact = isCompact
  }

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Label(
        "任务",
        systemImage: activityStatus.activeTaskCount > 0
          ? "list.bullet.rectangle.fill"
          : "list.bullet.rectangle")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: activityStatus.activeTaskCount > 0,
        showsTitle: false
      )
    )
    .frame(width: 30, height: 28)
    .overlay(alignment: .topTrailing) {
      if activityStatus.failedTaskCount > 0 {
        Text(activityStatus.failedTaskCount > 9 ? "9+" : "\(activityStatus.failedTaskCount)")
          .font(.workbenchMetadata.weight(.bold).monospacedDigit())
          .foregroundStyle(colorScheme == .dark ? .black : .white)
          .frame(width: activityStatus.failedTaskCount > 9 ? 19 : 14, height: 14)
          .background(WorkbenchTheme.risk, in: Capsule())
          .offset(x: -1, y: 2)
          .allowsHitTesting(false)
      }
    }
    .help(String(localized: "统一任务中心"))
    .accessibilityLabel("统一任务中心")
    .accessibilityValue(taskCenterAccessibilityValue)
    .accessibilityIdentifier("workspace-task-center-toggle")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      WorkspaceTaskCenterView(store: store)
    }
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

/// Search only searches: live article statistics belong to the editor's
/// status bar, so the toolbar never duplicates them.
struct OmniCommandSearchBar: View {
  let density: WorkspaceTopBarPresentation.Density
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        switch density {
        case .expanded:
          Text("搜索草稿、标签与指令…")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        case .compact:
          Text("搜索…")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        case .minimal:
          EmptyView()
        }

        if density != .minimal {
          Spacer(minLength: 4)

          Text("⇧⌘K")
            .font(.workbenchMetadata.weight(.bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 8)
      .frame(width: WorkspaceTopBarPresentation.searchWidth(for: density), height: 28)
      .background(
        Color.primary.opacity(0.06),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.searchBar, style: .continuous)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.searchBar, style: .continuous))
    }
    .buttonStyle(
      WorkbenchFocusRingButtonStyle(cornerRadius: WorkbenchCornerRadius.searchBar, lineWidth: 1.5)
    )
    .layoutPriority(1)
    .help(String(localized: "唤起命令面板与全局搜索 (⇧⌘K)"))
    .accessibilityLabel("全局搜索")
    .accessibilityIdentifier("workspace-command-search")
  }
}

enum WorkspaceToolbarButtonProminence: Equatable {
  case standard
  case primaryAction
}

struct WorkspaceToolbarIconButtonStyle: ButtonStyle {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let isActive: Bool
  let showsTitle: Bool
  let prominence: WorkspaceToolbarButtonProminence

  @Environment(\.isFocused) private var isFocused
  // Custom button styles do not inherit AppKit's disabled appearance, so the
  // style must dim itself; otherwise disabled commands look actionable.
  @Environment(\.isEnabled) private var isEnabled

  init(
    isActive: Bool,
    showsTitle: Bool = false,
    prominence: WorkspaceToolbarButtonProminence = .standard
  ) {
    self.isActive = isActive
    self.showsTitle = showsTitle
    self.prominence = prominence
  }

  func makeBody(configuration: Configuration) -> some View {
    styledLabel(configuration.label)
      .font(.workbenchButtonLabel)
      .symbolVariant(isActive ? .fill : .none)
      .foregroundStyle(foregroundColor)
      .padding(.horizontal, showsTitle ? 8 : 4)
      .frame(minWidth: showsTitle ? nil : 28, minHeight: 28)
      .fixedSize(horizontal: showsTitle, vertical: false)
      .background {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        shape
          .fill(backgroundColor(isPressed: configuration.isPressed))
          .overlay {
            if prominence == .primaryAction, isEnabled, configuration.isPressed {
              shape.fill(Color.black.opacity(0.12))
            }
          }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(
            isFocused ? workbenchAccentColor : Color.clear,
            lineWidth: isFocused ? 1.5 : 0
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  @ViewBuilder
  private func styledLabel(_ label: Configuration.Label) -> some View {
    if showsTitle {
      label.labelStyle(.titleAndIcon)
    } else {
      label.labelStyle(.iconOnly)
    }
  }

  private var foregroundColor: Color {
    guard isEnabled else { return Color(nsColor: .tertiaryLabelColor) }
    switch prominence {
    case .standard:
      return isActive ? workbenchAccentColor : Color.secondary
    case .primaryAction:
      return WorkbenchTheme.primaryActionForeground
    }
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if prominence == .primaryAction {
      guard isEnabled else { return Color.primary.opacity(0.08) }
      // Every primary action shares the brand fill; selection keeps following
      // the user's accent, so the CTA stays distinct from selected controls.
      return WorkbenchTheme.primaryActionFill
    }
    if isPressed {
      return Color.primary.opacity(0.08)
    }
    if isActive {
      return workbenchAccentColor.opacity(WorkbenchOpacity.selectionBackground)
    }
    return .clear
  }
}

/// A standalone sidebar command for the native navigation placement. The
/// parent owns the actual split-view visibility, while this component keeps
/// the selected/hidden state available to VoiceOver.
struct WorkspaceSidebarToggleToolbarButton: View {
  let visibility: WorkspaceTopBarPresentation.SidebarVisibility
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(visibility.title, systemImage: "sidebar.left")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: visibility == .visible,
        showsTitle: false
      )
    )
    .help(visibility.title)
    .accessibilityLabel(String(localized: "侧栏"))
    .accessibilityValue(visibility.accessibilityValue)
    .accessibilityIdentifier("workspace-sidebar-toggle")
  }
}

/// A single, independently accessible toolbar action. It deliberately stays
/// a `Button` so callers can place several instances in one native
/// `ToolbarItemGroup(.primaryAction)` without turning the action row into a
/// custom hit target or menu.
struct WorkspaceToolbarActionButton: View {
  let title: String
  let systemImage: String
  let accessibilityIdentifier: String
  let isActive: Bool
  let isEnabled: Bool
  let showsTitle: Bool
  let help: String
  let action: () -> Void

  init(
    title: String,
    systemImage: String,
    accessibilityIdentifier: String,
    isActive: Bool = false,
    isEnabled: Bool = true,
    showsTitle: Bool = false,
    help: String? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.accessibilityIdentifier = accessibilityIdentifier
    self.isActive = isActive
    self.isEnabled = isEnabled
    self.showsTitle = showsTitle
    self.help = help ?? title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: isActive,
        showsTitle: showsTitle
      )
    )
    .disabled(!isEnabled)
    .help(help)
    .accessibilityLabel(title)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

struct WorkspaceKnowledgeToolbar: View {
  @ObservedObject var commandRouter: WorkspaceSceneCommandRouter
  let isEnabled: Bool

  var body: some View {
    WorkspaceToolbarActionButton(
      title: String(localized: "导入资料"),
      systemImage: "square.and.arrow.down",
      accessibilityIdentifier: "workspace-library-import",
      isEnabled: isEnabled && commandRouter.knowledgeLibraryCommandActions != nil,
      action: { commandRouter.knowledgeLibraryCommandActions?.importSources() }
    )

    WorkspaceToolbarActionButton(
      title: String(localized: "新建笔记"),
      systemImage: "note.text.badge.plus",
      accessibilityIdentifier: "workspace-library-new-note",
      isEnabled: isEnabled && commandRouter.knowledgeLibraryCommandActions != nil,
      action: { commandRouter.knowledgeLibraryCommandActions?.createNote() }
    )
  }
}

struct WorkspacePreviewToolbarButton: View {
  let availability: WorkspaceTopBarPresentation.PreviewAvailability
  let showsTitle: Bool
  let openLivePreview: () -> Void
  let openBrowserPreview: () -> Void

  var body: some View {
    Menu {
      Button(action: openBrowserPreview) {
        Label(String(localized: "在浏览器打开当前文章"), systemImage: "safari")
      }
      .disabled(!availability.isBrowserPreviewEnabled)

      Button(action: openLivePreview) {
        Label(
          String(localized: "在应用内预览"),
          systemImage: availability.isLivePreviewRunning ? "play.rectangle.fill" : "play.rectangle"
        )
      }
      .disabled(!availability.isLivePreviewEnabled)
    } label: {
      // Menus ignore the toolbar ButtonStyle, so the title visibility must be
      // chosen on the label itself.
      if showsTitle {
        previewLabel.labelStyle(.titleAndIcon)
      } else {
        previewLabel.labelStyle(.iconOnly)
      }
    } primaryAction: {
      switch availability.defaultAction {
      case .browser: openBrowserPreview()
      case .inApp: openLivePreview()
      case .unavailable: break
      }
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.visible)
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: false,
        showsTitle: showsTitle
      )
    )
    .disabled(availability.defaultAction == .unavailable)
    .help(
      availability.defaultAction == .browser
        ? String(localized: "在系统浏览器中打开当前文章；按住可打开菜单")
        : String(localized: "在 RepoPress Studio 中打开实时预览")
    )
    .accessibilityLabel(String(localized: "预览"))
    .accessibilityValue(availability.accessibilityValue)
    .accessibilityIdentifier("workspace-preview")
  }

  private var previewLabel: Label<Text, Image> {
    Label(
      String(localized: "预览"),
      systemImage: availability.defaultAction == .browser ? "safari" : "play.rectangle"
    )
  }
}

/// A semantic blue publish CTA for the end of a primary-action toolbar group.
/// Availability remains a caller-provided value so the component never bypasses
/// the publishing flow's existing readiness checks.
struct WorkspacePreparePublishToolbarButton: View {
  let isEnabled: Bool
  let density: WorkspaceTopBarPresentation.Density
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(String(localized: "准备发布"), systemImage: "paperplane.fill")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: false,
        showsTitle: true,
        prominence: .primaryAction
      )
    )
    .disabled(!isEnabled)
    .help(String(localized: "打开本次发布清单和一键发布流程"))
    .accessibilityLabel(String(localized: "准备发布"))
    .accessibilityIdentifier("workspace-prepare-publish")
  }
}

struct WorkspaceToolbarLeadingContent: View {
  let store: WorkbenchStore
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  let isCompact: Bool
  let openSiteSettings: () -> Void

  init(store: WorkbenchStore, isCompact: Bool, openSiteSettings: @escaping () -> Void = {}) {
    self.store = store
    _shell = ObservedObject(wrappedValue: store.shell)
    self.isCompact = isCompact
    self.openSiteSettings = openSiteSettings
  }

  var body: some View {
    Menu {
      Picker(
        String(localized: "切换个人网站"),
        selection: Binding(
          get: { shell.activeProfileID },
          set: { store.selectProfile($0) }
        )
      ) {
        ForEach(shell.publishingProfiles) { profile in
          Text(profile.name).tag(profile.id)
        }
      }
      Divider()
      Button(String(localized: "站点设置…"), action: openSiteSettings)
    } label: {
      WorkspaceToolbarMenuLabel(
        title: shell.activeProfile.name,
        systemImage: "globe",
        showsTitle: !isCompact,
        siteKindDisplayName: shell.activeProfile.siteKind.localizedDisplayName
      )
      .frame(
        minWidth: isCompact ? 30 : nil,
        maxWidth: isCompact ? 30 : 220,
        minHeight: 28,
        alignment: .leading
      )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .buttonStyle(WorkbenchFocusRingButtonStyle(cornerRadius: 5, lineWidth: 1.5))
    .help(
      String(
        localized:
          "个人网站：\(shell.activeProfile.name) · \(shell.activeProfile.siteKind.localizedDisplayName)"
      )
    )
    .accessibilityLabel("切换个人网站")
    .accessibilityValue(shell.activeProfile.name)
    .accessibilityIdentifier("workspace-profile-menu")
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
  let canUseProtectedWorkbench: Bool
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
    canUseProtectedWorkbench: Bool,
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
    self.canUseProtectedWorkbench = canUseProtectedWorkbench
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
        .padding(.horizontal, isCompact ? 0 : 8)
        .frame(
          minWidth: isCompact ? 30 : 96,
          maxWidth: isCompact ? 30 : 200,
          minHeight: 28
        )
        .background(currentToolbarStatus.color.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle(cornerRadius: 13, lineWidth: 1.5))
    .disabled(!canUseProtectedWorkbench)
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
        severity: .error
      )
    case .remoteChanges(let count):
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "远端有 \(count) 项变化"),
        detail: String(localized: "同步前请审阅远端变更队列。"),
        statusImage: "arrow.down.doc",
        color: WorkbenchTheme.info,
        severity: .information
      )
    case .localChanges(let count):
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "本地有 \(count) 项变化"),
        detail: String(localized: "发布前请审阅本地差异。"),
        statusImage: "arrow.triangle.2.circlepath",
        color: WorkbenchTheme.warning,
        severity: .warning
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

  private var draftStatus: PublishingStatusPopoverItem {
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
