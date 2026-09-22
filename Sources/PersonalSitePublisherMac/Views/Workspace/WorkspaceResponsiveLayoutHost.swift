import SwiftUI

/// Observe this container directly so native Inspector hosting cannot swallow
/// the width preference. Only semantic band changes reach the workspace owner.
struct WorkspaceResponsiveLayoutHost<Content: View>: View {
  let content: Content
  let onChange: (WorkspaceResponsiveLayoutSnapshot) -> Void

  init(
    onChange: @escaping (WorkspaceResponsiveLayoutSnapshot) -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.content = content()
    self.onChange = onChange
  }

  var body: some View {
    content
      .onGeometryChange(for: WorkspaceResponsiveLayoutSnapshot.self) { geometry in
        WorkspaceResponsiveLayoutSnapshot(width: geometry.size.width)
      } action: { snapshot in
        onChange(snapshot)
      }
  }
}
