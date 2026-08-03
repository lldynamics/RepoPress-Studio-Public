import PublishingWorkbenchCore
import SwiftUI

struct AdvancedWorkspaceToolbarActions: View {
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  let canUseProtectedWorkbench: Bool
  let showsTitle: Bool
  let isFirstRunSetupComplete: Bool
  let presentFirstRunSetup: () -> Void

  init(
    store: WorkbenchStore,
    canUseProtectedWorkbench: Bool,
    isCompact: Bool,
    isFirstRunSetupComplete: Bool,
    presentFirstRunSetup: @escaping () -> Void
  ) {
    _shell = ObservedObject(wrappedValue: store.shell)
    self.canUseProtectedWorkbench = canUseProtectedWorkbench
    self.showsTitle = !isCompact
    self.isFirstRunSetupComplete = isFirstRunSetupComplete
    self.presentFirstRunSetup = presentFirstRunSetup
  }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(WorkspaceNavigationPresentation.secondaryEntryItems) { item in
        Button {
          shell.selectSection(item.section)
        } label: {
          Label(
            workspaceNavigationLocalizedKey(item.displayNameLocalizationKey),
            systemImage: item.systemImage
          )
        }
        .buttonStyle(
          WorkspaceToolbarIconButtonStyle(
            isActive: shell.selectedSection == item.section,
            showsTitle: showsTitle
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
      .buttonStyle(
        WorkspaceToolbarIconButtonStyle(
          isActive: false,
          showsTitle: showsTitle
        )
      )
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
