import PublishingWorkbenchCore
import SwiftUI

/// A narrow, keyboard-discoverable route selector used only while the compact
/// Inspector replaces the full sidebar. It intentionally has no contextual
/// lists, so changing a workspace continues through the window session owner.
struct WorkspaceCompactNavigationRail: View {
  static let primarySections = WorkspaceNavigationRouteDescriptor.primarySections

  let selectedSection: WorkspaceSection
  @Binding var contentHealthFilter: ContentHealthContextFilter
  let onSelectSection: (WorkspaceSection) -> Void

  var body: some View {
    VStack(spacing: 6) {
      ForEach(Self.primarySections) { section in
        sectionButton(section)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .frame(width: 52)
    .frame(maxHeight: .infinity, alignment: .top)
    .workbenchGlassContainer(material: .thinMaterial, drawsBorder: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("主要工作区")
    .accessibilityIdentifier("workspace-compact-navigation-rail")
  }

  private func sectionButton(_ section: WorkspaceSection) -> some View {
    let title = WorkspaceNavigationRouteDescriptor.title(for: section)
    let isSelected = selectedSection == section

    return Button {
      if section == .contentHealth, !isSelected {
        contentHealthFilter = .overview
      }
      onSelectSection(section)
    } label: {
      Image(systemName: section.systemImage)
        .font(.body.weight(.semibold))
        .frame(width: 32, height: 32)
        .foregroundStyle(isSelected ? WorkbenchTheme.navigationSelection : Color.secondary)
        .background {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
              isSelected
                ? AnyShapeStyle(
                  WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.accentBackground)
                )
                : AnyShapeStyle(Color.clear)
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle(cornerRadius: 7))
    .help("\(title)（\(section.keyboardShortcutLabel)）")
    .accessibilityLabel(WorkspaceNavigationRouteDescriptor.accessibilityLabel(for: section))
    .accessibilityValue(isSelected ? "已选中" : "未选中")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("workspace-compact-rail-\(section.rawValue)")
  }
}
