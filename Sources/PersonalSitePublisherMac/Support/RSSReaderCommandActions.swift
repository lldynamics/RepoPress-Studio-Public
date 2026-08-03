import SwiftUI

struct RSSReaderCommandActions {
  var canNavigatePrevious: Bool
  var canNavigateNext: Bool
  var canActOnArticle: Bool
  var focusSearch: () -> Void
  var navigatePrevious: () -> Void
  var navigateNext: () -> Void
  var toggleStarred: () -> Void
  var toggleRead: () -> Void
  var openOriginal: () -> Void
  var createHighlight: () -> Void
  var addNote: () -> Void
  var editTags: () -> Void
}

private struct RSSReaderCommandActionsKey: FocusedValueKey {
  typealias Value = RSSReaderCommandActions
}

extension FocusedValues {
  var rssReaderCommandActions: RSSReaderCommandActions? {
    get { self[RSSReaderCommandActionsKey.self] }
    set { self[RSSReaderCommandActionsKey.self] = newValue }
  }
}
