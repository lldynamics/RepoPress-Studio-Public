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
    }

    let isLivePreviewRunning: Bool
    let isBrowserPreviewEnabled: Bool

    var defaultAction: DefaultAction {
      if isBrowserPreviewEnabled { return .browser }
      return .inApp
    }

    var accessibilityValue: String {
      switch defaultAction {
      case .browser: return String(localized: "在浏览器中预览当前文章")
      case .inApp:
        return isLivePreviewRunning ? String(localized: "正在运行") : String(localized: "准备就绪")
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
    case .writing, .contentHealth:
      return true
    case .sync, .library, .rss, .images:
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
  let open: () -> Void

  init(store: WorkbenchStore, open: @escaping () -> Void) {
    _activityStatus = ObservedObject(wrappedValue: store.activityStatus)
    self.open = open
  }

  var body: some View {
    Button(action: open) {
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
    .help(String(localized: "任务中心（⌥⌘L）"))
    .accessibilityLabel("任务中心")
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

  var body: some View {
    WorkspaceToolbarActionButton(
      title: String(localized: "导入资料"),
      systemImage: "square.and.arrow.down",
      accessibilityIdentifier: "workspace-library-import",
      isEnabled: commandRouter.knowledgeLibraryCommandActions != nil,
      action: { commandRouter.knowledgeLibraryCommandActions?.importSources() }
    )

    WorkspaceToolbarActionButton(
      title: String(localized: "新建笔记"),
      systemImage: "note.text.badge.plus",
      accessibilityIdentifier: "workspace-library-new-note",
      isEnabled: commandRouter.knowledgeLibraryCommandActions != nil,
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
/// Opens the publishing review; readiness checks belong to the publishing flow.
struct WorkspacePreparePublishToolbarButton: View {
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
