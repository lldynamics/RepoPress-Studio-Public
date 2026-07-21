import SwiftUI

struct RepositorySourceEditorCommandActions {
  var hasDocument: Bool
  var canSave: Bool
  var save: () -> Void
  var showFind: () -> Void
  var findNext: () -> Void
  var findPrevious: () -> Void
  var reload: () -> Void
}

struct RepositorySourceSessionCommandActions {
  var hasUnsavedChanges: Bool
  var save: () -> Bool
  var lastErrorMessage: () -> String?
}

private struct RepositorySourceEditorCommandActionsKey: FocusedValueKey {
  typealias Value = RepositorySourceEditorCommandActions
}

private struct RepositorySourceSessionCommandActionsKey: FocusedValueKey {
  typealias Value = RepositorySourceSessionCommandActions
}

extension FocusedValues {
  var repositorySourceEditorCommandActions: RepositorySourceEditorCommandActions? {
    get { self[RepositorySourceEditorCommandActionsKey.self] }
    set { self[RepositorySourceEditorCommandActionsKey.self] = newValue }
  }

  var repositorySourceSessionCommandActions: RepositorySourceSessionCommandActions? {
    get { self[RepositorySourceSessionCommandActionsKey.self] }
    set { self[RepositorySourceSessionCommandActionsKey.self] = newValue }
  }
}
