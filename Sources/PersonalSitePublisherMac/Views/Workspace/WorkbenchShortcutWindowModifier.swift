import SwiftUI

struct WorkbenchShortcutWindowModifier: ViewModifier {
  let windowID: UUID
  let isKeyWindow: Bool
  let handler: (WorkbenchShortcutRequest) -> Void

  func body(content: Content) -> some View {
    content
      .onAppear(perform: register)
      .onChange(of: isKeyWindow) { _, _ in register() }
      .onChange(of: windowID) { previous, _ in
        WorkbenchShortcutCoordinator.shared.unregister(windowID: previous)
        register()
      }
      .onDisappear { WorkbenchShortcutCoordinator.shared.unregister(windowID: windowID) }
  }

  private func register() {
    WorkbenchShortcutCoordinator.shared.register(
      windowID: windowID, isKeyWindow: isKeyWindow, handler: handler
    )
  }
}
