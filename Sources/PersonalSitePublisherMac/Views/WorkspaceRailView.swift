import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskNavigation: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var contentHealthFilter: ContentHealthContextFilter
  let onSelectSection: (WorkspaceSection) -> Void

  var body: some View {
    List(selection: navigationSelection) {
      Section {
        sectionRow(.writing)
        sectionRow(.library)
        sectionRow(.sync)
        sectionRow(.images)
        sectionRow(.contentHealth)
      }

    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .accessibilityIdentifier("workspace-task-navigation")
  }

  private var navigationSelection: Binding<WorkspaceSection?> {
    Binding(
      get: { store.selectedSection },
      set: { selection in
        guard let selection else { return }
        if selection == .contentHealth, store.selectedSection != .contentHealth {
          contentHealthFilter = .overview
        }
        onSelectSection(selection)
      }
    )
  }

  private func sectionRow(_ section: WorkspaceSection) -> some View {
    let title = workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
    return navigationLabel(
      title,
      systemImage: section.systemImage
    )
    .tag(section)
    .help(title)
    .accessibilityLabel(workspaceNavigationLocalizedKey(section.displayNameLocalizationKey))
    .accessibilityIdentifier("workspace-sidebar-\(section.rawValue)")
  }

  private func navigationLabel(
    _ title: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 9) {
      Image(systemName: systemImage)
        .frame(width: 16)
        .foregroundStyle(Color.secondary)

      Text(title)
        .workbenchTruncatedIdentity(title)

      Spacer(minLength: 8)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(Color.primary)
    .contentShape(Rectangle())
  }
}
