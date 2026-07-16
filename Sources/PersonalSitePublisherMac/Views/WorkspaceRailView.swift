import PublishingWorkbenchCore
import SwiftUI

private enum WorkspaceTaskNavigationSelection: Hashable {
  case section(WorkspaceSection)
  case contentHealth(ContentHealthContextFilter)
}

struct WorkspaceTaskNavigation: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var contentHealthFilter: ContentHealthContextFilter
  let onSelectSection: (WorkspaceSection) -> Void

  var body: some View {
    List(selection: navigationSelection) {
      Section {
        sectionRow(.writing)
        sectionRow(.sync)
        sectionRow(.images)
        sectionRow(.contentHealth)
      }

      if store.selectedSection == .contentHealth {
        Section("查看") {
          navigationLabel("问题", systemImage: "checklist")
            .tag(WorkspaceTaskNavigationSelection.contentHealth(.overview))
          navigationLabel("站点维护", systemImage: "wrench.and.screwdriver")
            .tag(WorkspaceTaskNavigationSelection.contentHealth(.maintenance))
        }
      }

    }
    .listStyle(.sidebar)
    .accessibilityIdentifier("workspace-task-navigation")
  }

  private var navigationSelection: Binding<WorkspaceTaskNavigationSelection?> {
    Binding(
      get: {
        if store.selectedSection == .contentHealth {
          return .contentHealth(contentHealthFilter == .maintenance ? .maintenance : .overview)
        }
        return .section(store.selectedSection)
      },
      set: { selection in
        guard let selection else { return }
        switch selection {
        case .section(let section):
          if section == .contentHealth {
            contentHealthFilter = .overview
          }
          onSelectSection(section)
        case .contentHealth(let filter):
          contentHealthFilter = filter
          onSelectSection(.contentHealth)
        }
      }
    )
  }

  private func sectionRow(_ section: WorkspaceSection) -> some View {
    navigationLabel(
      workspaceNavigationLocalizedKey(section.displayNameLocalizationKey),
      systemImage: section.systemImage
    )
    .tag(WorkspaceTaskNavigationSelection.section(section))
    .help(workspaceNavigationLocalizedString(section.displayNameLocalizationKey))
    .accessibilityLabel(workspaceNavigationLocalizedKey(section.displayNameLocalizationKey))
    .accessibilityIdentifier("workspace-sidebar-\(section.rawValue)")
  }

  private func navigationLabel(
    _ title: LocalizedStringKey,
    systemImage: String
  ) -> some View {
    HStack(spacing: 9) {
      Image(systemName: systemImage)
        .frame(width: 16)
        .foregroundStyle(Color.secondary)

      Text(title)
        .lineLimit(1)

      Spacer(minLength: 8)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(Color.primary)
    .contentShape(Rectangle())
  }
}
