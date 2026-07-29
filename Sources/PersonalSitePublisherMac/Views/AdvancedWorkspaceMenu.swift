import PublishingWorkbenchCore
import SwiftUI

struct AdvancedWorkspaceToolbarActions: View {
  @ObservedObject var store: WorkbenchStore
  let canUseProtectedWorkbench: Bool
  let isFirstRunSetupComplete: Bool
  let presentFirstRunSetup: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(WorkspaceNavigationPresentation.secondaryEntryItems) { item in
        Button {
          store.selectSection(item.section)
        } label: {
          Label(
            workspaceNavigationLocalizedKey(item.displayNameLocalizationKey),
            systemImage: item.systemImage
          )
        }
        .buttonStyle(
          WorkspaceToolbarIconButtonStyle(
            isActive: store.selectedSection == item.section
          )
        )
        .help(workspaceNavigationLocalizedString(item.displayNameLocalizationKey))
        .accessibilityLabel(
          workspaceNavigationLocalizedKey(item.displayNameLocalizationKey)
        )
        .accessibilityIdentifier(
          "workspace-secondary-\(item.section.rawValue)"
        )
      }

      Button(action: presentFirstRunSetup) {
        Label(
          isFirstRunSetupComplete
            ? String(localized: "重新运行设置向导…")
            : String(localized: "首次设置…"),
          systemImage: "wand.and.stars"
        )
      }
      .buttonStyle(WorkspaceToolbarIconButtonStyle(isActive: false))
      .help(
        isFirstRunSetupComplete
          ? String(localized: "重新运行设置向导…")
          : String(localized: "首次设置…")
      )
      .accessibilityLabel(
        isFirstRunSetupComplete
          ? String(localized: "重新运行设置向导…")
          : String(localized: "首次设置…")
      )
      .accessibilityIdentifier("workspace-first-run-setup")
    }
    .disabled(!canUseProtectedWorkbench)
  }
}
