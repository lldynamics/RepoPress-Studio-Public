import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskNavigation: View {
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
    VStack(spacing: 8) {
      ForEach(Array(WorkspaceNavigationRouteDescriptor.primaryRows.enumerated()), id: \.offset) {
        row in
        HStack(spacing: row.offset == 0 ? 8 : 6) {
          ForEach(row.element) { section in
            sectionButton(section, prominence: row.offset == 0 ? .primary : .compact)
          }
        }
      }
    }
    .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
    .padding(.vertical, WorkspaceSidebarMetrics.headerVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-task-navigation")
  }

  private func sectionButton(
    _ section: WorkspaceSection,
    prominence: NavigationButtonProminence
  ) -> some View {
    let title = WorkspaceNavigationRouteDescriptor.title(for: section)
    let isSelected = selectedSection == section

    return Button {
      if section == .contentHealth, !isSelected {
        contentHealthFilter = .overview
      }
      onSelectSection(section)
    } label: {
      HStack(spacing: prominence.labelSpacing) {
        Image(systemName: section.systemImage)
          .font(.system(size: prominence.iconSize, weight: .medium))
          .frame(width: prominence.iconWidth)
          .accessibilityHidden(true)

        Text(title)
          .font(prominence.font)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }
      .foregroundStyle(isSelected ? WorkbenchTheme.navigationSelection : Color.primary)
      .frame(maxWidth: .infinity, minHeight: 32)
      .padding(.horizontal, prominence.horizontalPadding)
      .background {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .fill(
            isSelected
              ? AnyShapeStyle(
                WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.accentBackground)
              )
              : WorkbenchBackgroundStyle.control
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .strokeBorder(
            isSelected
              ? WorkbenchTheme.navigationSelection.opacity(0.30)
              : Color.primary.opacity(0.08),
            lineWidth: 1
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle())
    .help(title + shortcutHint(for: section))
    .accessibilityLabel(WorkspaceNavigationRouteDescriptor.accessibilityLabel(for: section))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("workspace-sidebar-\(section.rawValue)")
  }

  private func shortcutHint(for section: WorkspaceSection) -> String {
    guard WorkspaceNavigationPresentation.commandMenuItems.contains(where: {
      $0.section == section
    }) else {
      return ""
    }
    return "（\(section.keyboardShortcutLabel)）"
  }
}

private enum NavigationButtonProminence {
  case primary
  case compact

  var font: Font {
    .workbenchButtonLabel
  }

  var iconSize: CGFloat {
    self == .primary ? 14 : 12
  }

  var iconWidth: CGFloat {
    self == .primary ? 16 : 13
  }

  var labelSpacing: CGFloat {
    self == .primary ? 6 : 4
  }

  var horizontalPadding: CGFloat {
    self == .primary ? 8 : 4
  }
}
