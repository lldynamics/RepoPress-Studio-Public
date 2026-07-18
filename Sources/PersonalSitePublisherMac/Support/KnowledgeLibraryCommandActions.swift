import SwiftUI

struct KnowledgeLibraryCommandActions {
  var focusSearch: () -> Void
  var importSources: () -> Void
  var selectPreviousDocument: () -> Void
  var selectNextDocument: () -> Void
}

private struct KnowledgeLibraryCommandActionsKey: FocusedValueKey {
  typealias Value = KnowledgeLibraryCommandActions
}

extension FocusedValues {
  var knowledgeLibraryCommandActions: KnowledgeLibraryCommandActions? {
    get { self[KnowledgeLibraryCommandActionsKey.self] }
    set { self[KnowledgeLibraryCommandActionsKey.self] = newValue }
  }
}
