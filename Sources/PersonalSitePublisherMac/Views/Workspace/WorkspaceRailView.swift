import PublishingWorkbenchCore
import SwiftUI

/// The single primary-navigation rail used at every responsive width. Context
/// lists may yield to the editor or Inspector, but this route anchor stays in
/// the same place until focus mode deliberately removes workspace chrome.
struct WorkspacePrimaryNavigationRail: View {
  static let width = WorkbenchLayoutMode.primaryNavigationRailWidth
  static let primarySections = WorkspaceNavigationRouteDescriptor.primarySections

  @WorkspaceModuleVisibilityStorage private var moduleVisibility
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var activityStatus: WorkbenchActivityStatusFacade
  let selectedSection: WorkspaceSection
  let siteIssueCount: Int?
  let onSelectSection: (WorkspaceSection) -> Void
  let openTaskCenter: () -> Void

  init(
    store: WorkbenchStore,
    selectedSection: WorkspaceSection,
    siteIssueCount: Int?,
    onSelectSection: @escaping (WorkspaceSection) -> Void,
    openTaskCenter: @escaping () -> Void
  ) {
    _activityStatus = ObservedObject(wrappedValue: store.activityStatus)
    self.selectedSection = selectedSection
    self.siteIssueCount = siteIssueCount
    self.onSelectSection = onSelectSection
    self.openTaskCenter = openTaskCenter
  }

  var body: some View {
    VStack(spacing: WorkbenchSpacing.tight) {
      ForEach(moduleVisibility.primarySections) { section in
        sectionButton(section)
      }

      Spacer(minLength: WorkbenchSpacing.control)

      taskCenterButton
    }
    .padding(.horizontal, WorkbenchSpacing.tight)
    .padding(.vertical, WorkbenchSpacing.control)
    .frame(width: Self.width)
    .frame(maxHeight: .infinity)
    .background(WorkbenchSurface.sidebar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("主要工作区")
    .accessibilityIdentifier("workspace-primary-navigation-rail")
  }

  private func sectionButton(_ section: WorkspaceSection) -> some View {
    let title = WorkspaceNavigationRouteDescriptor.title(for: section)
    let isSelected =
      WorkspaceNavigationRouteDescriptor.primarySection(for: selectedSection) == section

    return Button {
      onSelectSection(section)
    } label: {
      VStack(spacing: 3) {
        Image(systemName: section.systemImage)
          .font(.system(size: WorkbenchIconSize.toolbar, weight: .semibold))
          .frame(height: 18)
          .overlay(alignment: .topTrailing) {
            if section == .sync, let count = siteIssueCount, count > 0 {
              issueBadge(count, color: WorkbenchTheme.warning)
                .offset(x: 10, y: -6)
            }
          }

        Text(WorkspaceNavigationRouteDescriptor.accessibilityLabel(for: section))
          .font(.workbenchMetadata)
          .lineLimit(1)
      }
      .foregroundStyle(isSelected ? workbenchAccentColor : Color.secondary)
      .frame(maxWidth: .infinity, minHeight: 46)
      .background {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control, style: .continuous)
          .fill(
            isSelected
              ? AnyShapeStyle(
                workbenchAccentColor.opacity(WorkbenchOpacity.accentBackground)
              )
              : AnyShapeStyle(Color.clear)
          )
      }
      .contentShape(
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control, style: .continuous)
      )
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle(cornerRadius: WorkbenchCornerRadius.control))
    .help(
      [
        title + shortcutHint(for: section),
        WorkspaceNavigationRouteDescriptor.checksHint(for: section, issueCount: siteIssueCount),
      ]
      .filter { !$0.isEmpty }.joined(separator: "\n")
    )
    .accessibilityLabel(WorkspaceNavigationRouteDescriptor.accessibilityLabel(for: section))
    .accessibilityValue(isSelected ? "已选中" : "未选中")
    .accessibilityHint(
      WorkspaceNavigationRouteDescriptor.checksHint(for: section, issueCount: siteIssueCount)
    )
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("workspace-sidebar-\(section.rawValue)")
  }

  private var taskCenterButton: some View {
    Button(action: openTaskCenter) {
      VStack(spacing: 3) {
        Image(
          systemName: activityStatus.activeTaskCount > 0
            ? "list.bullet.rectangle.fill"
            : "list.bullet.rectangle"
        )
        .font(.system(size: WorkbenchIconSize.toolbar, weight: .semibold))
        .frame(height: 18)
        .overlay(alignment: .topTrailing) {
          if activityStatus.failedTaskCount > 0 {
            issueBadge(activityStatus.failedTaskCount, color: WorkbenchTheme.risk)
              .offset(x: 10, y: -6)
          }
        }

        Text("任务")
          .font(.workbenchMetadata)
      }
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 46)
      .contentShape(
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control, style: .continuous)
      )
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle(cornerRadius: WorkbenchCornerRadius.control))
    .help(String(localized: "任务中心（⌥⌘L）"))
    .accessibilityLabel("任务中心")
    .accessibilityValue(taskCenterAccessibilityValue)
    .accessibilityIdentifier("workspace-task-center-toggle")
  }

  private func issueBadge(_ count: Int, color: Color) -> some View {
    Text(verbatim: count > 99 ? "99+" : "\(count)")
      .font(.workbenchMetadata.weight(.bold).monospacedDigit())
      .foregroundStyle(colorScheme == .dark ? .black : .white)
      .padding(.horizontal, WorkbenchSpacing.tight)
      .frame(minWidth: 14, minHeight: 14)
      .background(color, in: Capsule())
      .fixedSize()
      .accessibilityHidden(true)
  }

  private var taskCenterAccessibilityValue: String {
    if activityStatus.activeTaskCount == 0, activityStatus.failedTaskCount == 0 {
      return String(localized: "无进行中或失败任务")
    }
    return String(
      localized: "进行中 \(activityStatus.activeTaskCount)，失败 \(activityStatus.failedTaskCount)"
    )
  }

  private func shortcutHint(for section: WorkspaceSection) -> String {
    guard
      WorkspaceNavigationPresentation.commandMenuItems.contains(where: {
        $0.section == section
      })
    else {
      return ""
    }
    return "（\(section.keyboardShortcutLabel)）"
  }
}
