import SwiftUI

struct WorkspaceFirstRunSetupCommandAction {
  let open: () -> Void
}

private struct WorkspaceFirstRunSetupCommandActionKey: FocusedValueKey {
  typealias Value = WorkspaceFirstRunSetupCommandAction
}

extension FocusedValues {
  var workspaceFirstRunSetupCommandAction: WorkspaceFirstRunSetupCommandAction? {
    get { self[WorkspaceFirstRunSetupCommandActionKey.self] }
    set { self[WorkspaceFirstRunSetupCommandActionKey.self] = newValue }
  }
}
