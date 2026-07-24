import SwiftUI

struct DraftFullTextSearchAction {
  let open: () -> Void
}

private struct DraftFullTextSearchActionKey: FocusedValueKey {
  typealias Value = DraftFullTextSearchAction
}

extension FocusedValues {
  var draftFullTextSearchAction: DraftFullTextSearchAction? {
    get { self[DraftFullTextSearchActionKey.self] }
    set { self[DraftFullTextSearchActionKey.self] = newValue }
  }
}
