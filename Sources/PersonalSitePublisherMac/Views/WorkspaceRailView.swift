import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceRail: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    VStack(spacing: 6) {
      ForEach(WorkspaceNavigationPresentation.primaryAreas) { area in
        ForEach(WorkspaceNavigationPresentation.primarySections(in: area)) { section in
          sectionButton(section)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("工作区导航")
  }

  private func sectionButton(_ section: WorkspaceSection) -> some View {
    let isSelected = store.selectedSection == section
    return Button {
      store.selectSection(section)
    } label: {
      Image(systemName: section.systemImage)
        .frame(width: 30, height: 30)
        .foregroundStyle(isSelected ? WorkbenchTheme.primary : Color.secondary)
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .fill(WorkbenchTheme.primary.opacity(WorkbenchOpacity.accentBackground))
          }
        }
    }
    .buttonStyle(.plain)
    .help(workspaceNavigationLocalizedString(section.displayNameLocalizationKey))
    .accessibilityLabel(workspaceNavigationLocalizedKey(section.displayNameLocalizationKey))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
