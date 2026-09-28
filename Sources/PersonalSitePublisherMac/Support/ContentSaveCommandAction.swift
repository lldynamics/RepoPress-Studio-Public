import SwiftUI

struct ContentSaveCommandAction {
  let title: String
  let isEnabled: Bool
  let save: () -> Void
}

private struct ContentSaveCommandActionKey: FocusedValueKey {
  typealias Value = ContentSaveCommandAction
}

extension FocusedValues {
  var contentSaveCommandAction: ContentSaveCommandAction? {
    get { self[ContentSaveCommandActionKey.self] }
    set { self[ContentSaveCommandActionKey.self] = newValue }
  }
}
