import SwiftUI

struct WorkspaceCommandPaletteAction {
  let open: () -> Void
}

private struct WorkspaceCommandPaletteActionKey: FocusedValueKey {
  typealias Value = WorkspaceCommandPaletteAction
}

extension FocusedValues {
  var workspaceCommandPaletteAction: WorkspaceCommandPaletteAction? {
    get { self[WorkspaceCommandPaletteActionKey.self] }
    set { self[WorkspaceCommandPaletteActionKey.self] = newValue }
  }
}
