import SwiftUI

@MainActor
struct WorkspaceCommandSearchToolbarControl: View {
  let density: WorkspaceTopBarPresentation.Density
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    WorkspaceCommandSearchNativeHost(
      density: density,
      isEnabled: isEnabled,
      action: action
    )
    .frame(width: WorkspaceTopBarPresentation.searchWidth(for: density), height: 28)
  }
}
