import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskNavigation: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let store: WorkbenchStore
  let selectedSection: WorkspaceSection
  @Binding var contentHealthFilter: ContentHealthContextFilter
  let onSelectSection: (WorkspaceSection) -> Void

  init(
    store: WorkbenchStore,
    selectedSection: WorkspaceSection,
    contentHealthFilter: Binding<ContentHealthContextFilter>,
    onSelectSection: @escaping (WorkspaceSection) -> Void
  ) {
    self.store = store
    self.selectedSection = selectedSection
    _contentHealthFilter = contentHealthFilter
    self.onSelectSection = onSelectSection
  }

  var body: some View {
    HStack(spacing: 4) {
      ForEach(WorkspaceNavigationRouteDescriptor.primarySections) { section in
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
      if section == .contentHealth, !isSelected {
        contentHealthFilter = .overview
      }
      onSelectSection(section)
    } label: {
      Image(systemName: section.systemImage)
        .font(.system(size: 15, weight: .medium))
        .frame(maxWidth: .infinity, minHeight: 32)
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
    .help(title + shortcutHint(for: section))
    .accessibilityLabel(WorkspaceNavigationRouteDescriptor.accessibilityLabel(for: section))
    .accessibilityValue(isSelected ? "已选中" : "未选中")
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
