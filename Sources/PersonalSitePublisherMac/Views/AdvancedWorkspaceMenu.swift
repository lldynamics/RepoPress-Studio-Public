import PublishingWorkbenchCore
import SwiftUI

struct AdvancedWorkspaceMenu: View {
  @ObservedObject var store: WorkbenchStore
  let canUseProtectedWorkbench: Bool
  let isFirstRunSetupComplete: Bool
  let presentFirstRunSetup: () -> Void

  var body: some View {
    Group {
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

      Divider()

      Button(action: presentFirstRunSetup) {
        Label(
          isFirstRunSetupComplete
            ? String(localized: "重新运行设置向导…")
            : String(localized: "首次设置…"),
          systemImage: "wand.and.stars"
        )
      }
    }
    .disabled(!canUseProtectedWorkbench)
  }
}
