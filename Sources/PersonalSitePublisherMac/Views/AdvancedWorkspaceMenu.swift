import PublishingWorkbenchCore
import SwiftUI

struct AdvancedWorkspaceMenu: View {
  @ObservedObject var store: WorkbenchStore
  let canUseProtectedWorkbench: Bool
  let showsFirstRunSetup: Bool
  let presentFirstRunSetup: () -> Void

  var body: some View {
    Menu {
      ForEach(WorkspaceNavigationPresentation.secondaryEntryItems) { item in
        Button {
          store.selectSection(item.section)
        } label: {
          Label(
            workspaceNavigationLocalizedKey(item.displayNameLocalizationKey),
            systemImage: item.systemImage
          )
        }
      }

      if showsFirstRunSetup {
        Divider()

        Button(action: presentFirstRunSetup) {
          Label("首次设置…", systemImage: "wand.and.stars")
        }
      }
    } label: {
      Label("高级工具", systemImage: "wrench.and.screwdriver")
    }
    .disabled(!canUseProtectedWorkbench)
    .accessibilityLabel("高级工具")
  }
}
