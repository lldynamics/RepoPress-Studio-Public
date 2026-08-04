import SwiftUI

struct WorkspaceFocusModeCommandAction {
  let isActive: Bool
  let canToggle: Bool
  let toggle: () -> Void
}

private struct WorkspaceFocusModeCommandActionKey: FocusedValueKey {
  typealias Value = WorkspaceFocusModeCommandAction
}

extension FocusedValues {
  var workspaceFocusModeCommandAction: WorkspaceFocusModeCommandAction? {
    get { self[WorkspaceFocusModeCommandActionKey.self] }
    set { self[WorkspaceFocusModeCommandActionKey.self] = newValue }
  }
}
