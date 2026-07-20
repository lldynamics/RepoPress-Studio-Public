import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskNavigation: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var contentHealthFilter: ContentHealthContextFilter
  let onSelectSection: (WorkspaceSection) -> Void

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        sectionButton(.writing, prominence: .primary)
        sectionButton(.library, prominence: .primary)
      }

      HStack(spacing: 6) {
        sectionButton(.sync, prominence: .compact)
        sectionButton(.images, prominence: .compact)
        sectionButton(.contentHealth, prominence: .compact)
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
    let title = workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
    let isSelected = store.selectedSection == section

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
          .lineLimit(1)
          .minimumScaleFactor(0.85)
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
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(workspaceNavigationLocalizedKey(section.displayNameLocalizationKey))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("workspace-sidebar-\(section.rawValue)")
  }
}

private enum NavigationButtonProminence {
  case primary
  case compact

  var font: Font {
    switch self {
    case .primary:
      return .callout.weight(.medium)
    case .compact:
      return .caption.weight(.medium)
    }
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
