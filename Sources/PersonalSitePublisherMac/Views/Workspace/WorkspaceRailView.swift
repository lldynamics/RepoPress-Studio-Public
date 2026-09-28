import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskNavigation: View {
  @WorkspaceModuleVisibilityStorage private var moduleVisibility
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let selectedSection: WorkspaceSection
  let siteIssueCount: Int?
  let onSelectSection: (WorkspaceSection) -> Void

  init(
    selectedSection: WorkspaceSection,
    siteIssueCount: Int?,
    onSelectSection: @escaping (WorkspaceSection) -> Void
  ) {
    self.selectedSection = selectedSection
    self.siteIssueCount = siteIssueCount
    self.onSelectSection = onSelectSection
  }

  var body: some View {
    HStack(spacing: 4) {
      ForEach(moduleVisibility.primarySections) { section in
        sectionButton(section)
      }
    }
    .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
    .padding(.vertical, WorkspaceSidebarMetrics.headerVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-task-navigation")
  }

  private func sectionButton(_ section: WorkspaceSection) -> some View {
    let title = WorkspaceNavigationRouteDescriptor.title(for: section)
    let isSelected =
      WorkspaceNavigationRouteDescriptor.primarySection(for: selectedSection) == section

    return Button {
      onSelectSection(section)
    } label: {
      VStack(spacing: 4) {
        Image(systemName: section.systemImage)
          .font(.system(size: 15, weight: .medium))
          .overlay(alignment: .topTrailing) {
            if section == .sync, (siteIssueCount ?? 0) > 0 {
              Circle()
                .fill(WorkbenchTheme.warning)
                .frame(width: 6, height: 6)
                .offset(x: 5, y: -2)
            }
          }
        Text(WorkspaceNavigationRouteDescriptor.accessibilityLabel(for: section))
          .font(.workbenchMetadata)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, minHeight: 48)
      .foregroundStyle(isSelected ? workbenchAccentColor : Color.primary)
      .background {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .fill(
            isSelected
              ? AnyShapeStyle(
                workbenchAccentColor.opacity(WorkbenchOpacity.accentBackground)
              )
              : WorkbenchBackgroundStyle.control
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .strokeBorder(
            isSelected
              ? workbenchAccentColor.opacity(0.30)
              : Color.primary.opacity(0.08),
            lineWidth: 1
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle())
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
