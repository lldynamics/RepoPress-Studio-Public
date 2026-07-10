import SwiftUI

struct PublishDrawerCommandAction {
  var open: (_ message: String?) -> Void
}

private struct PublishDrawerCommandActionKey: FocusedValueKey {
  typealias Value = PublishDrawerCommandAction
}

extension FocusedValues {
  var publishDrawerCommandAction: PublishDrawerCommandAction? {
    get { self[PublishDrawerCommandActionKey.self] }
    set { self[PublishDrawerCommandActionKey.self] = newValue }
  }
}
