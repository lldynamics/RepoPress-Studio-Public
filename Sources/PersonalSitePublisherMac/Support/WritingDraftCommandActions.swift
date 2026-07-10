import SwiftUI

struct WritingDraftCommandActions {
  var createDraft: () -> Void
  var focusSearch: () -> Void
  var selectPreviousDraft: () -> Void
  var selectNextDraft: () -> Void
}

private struct WritingDraftCommandActionsKey: FocusedValueKey {
  typealias Value = WritingDraftCommandActions
}

extension FocusedValues {
  var writingDraftCommandActions: WritingDraftCommandActions? {
    get { self[WritingDraftCommandActionsKey.self] }
    set { self[WritingDraftCommandActionsKey.self] = newValue }
  }
}
